#' Natural Spline Basis Functions
#'
#' `step_ns` creates a *specification* of a recipe step
#'  that will create new columns that are basis expansions of
#'  variables using natural splines.
#'
#' @inheritParams step_center
#' @param ... One or more selector functions to choose which
#'  variables are affected by the step. See [selections()]
#'  for more details.
#' @param role For model terms created by this step, what analysis
#'  role should they be assigned?. By default, the function assumes
#'  that the new columns created from the original variables will be
#'  used as predictors in a model.
#' @param deg_free The degrees of freedom for the natural spline. As the
#'  degrees of freedom for a natural spline increase, more flexible and
#'  complex curves can be generated. When a single degree of freedom is used,
#'  the result is a rescaled version of the original data.
#' @param objects A list of [splines::ns()] objects
#'  created once the step has been trained.
#' @param options A list of options for [splines::ns()]
#'  which should not include `x` or `df`.
#' @return An updated version of `recipe` with the new step
#'  added to the sequence of existing steps (if any).
#' @keywords datagen
#' @concept preprocessing
#' @concept basis_expansion
#' @export
#' @details `step_ns` can create new features from a single variable
#'  that enable fitting routines to model this variable in a
#'  nonlinear manner. The extent of the possible nonlinearity is
#'  determined by the `df` or `knot` arguments of
#'  [splines::ns()]. The original variables are removed
#'  from the data and new columns are added. The naming convention
#'  for the new variables is `varname_ns_1` and so on.
#'
#'  When you [`tidy()`] this step, a tibble with column `terms` (the
#'  columns that will be affected) is returned.
#'
#' @examples
#' library(modeldata)
#' data(biomass)
#'
#' biomass_tr <- biomass[biomass$dataset == "Training",]
#' biomass_te <- biomass[biomass$dataset == "Testing",]
#'
#' rec <- recipe(HHV ~ carbon + hydrogen + oxygen + nitrogen + sulfur,
#'               data = biomass_tr)
#'
#' with_splines <- rec %>%
#'   step_ns(carbon, hydrogen)
#' with_splines <- prep(with_splines, training = biomass_tr)
#'
#' expanded <- bake(with_splines, biomass_te)
#' expanded
#' @seealso [step_poly()] [recipe()]
#'   [prep.recipe()] [bake.recipe()]

step_ns <-
  function(recipe,
           ...,
           role = "predictor",
           trained = FALSE,
           objects = NULL,
           deg_free = 2,
           options = list(),
           skip = FALSE,
           id = rand_id("ns")) {
    add_step(
      recipe,
      step_ns_new(
        terms = ellipse_check(...),
        trained = trained,
        deg_free = deg_free,
        role = role,
        objects = objects,
        options = options,
        skip = skip,
        id = id
      )
    )
  }

step_ns_new <-
  function(terms, role, trained, deg_free, objects, options, skip, id) {
    step(
      subclass = "ns",
      terms = terms,
      role = role,
      trained = trained,
      deg_free = deg_free,
      objects = objects,
      options = options,
      skip = skip,
      id = id
    )
  }

ns_statistics <- function(x, args) {
  # Only do the parameter computations from splines::bs() / splines::ns(), don't evaluate at x.
  degree <- 1L
  intercept <- as.logical(args$intercept %||% FALSE)
  # This behaves differently from splines::ns() if length(x) is 1
  boundary <- sort(args$Boundary.knots) %||% range(x)

  # This behaves differently from splines::bs() and splines::ns() if num_knots < 0L
  # the original implementations issue a warning.
  if (!is.null(args$df) && is.null(args$knots) && args$df - degree - intercept >= 1L) {
    num_knots <- args$df - degree - intercept
    ok <- !is.na(x) & x >= boundary[1L] & x <= boundary[2L]
    knots <- unname(quantile(x[ok], seq_len(num_knots) / (num_knots + 1L)))
  } else {
    knots <- numeric()
  }

  # Only construct the data necessary for splines_predict
  out <- matrix(NA, ncol = degree + length(knots) + intercept, nrow = 1L)
  class(out) <- c("ns", "basis", "matrix")
  attr(out, "knots") <- knots
  attr(out, "Boundary.knots") <- boundary
  attr(out, "intercept") <- intercept
  out
}

ns_predict <- function(object, x) {
  xu <- unique(x)
  ru <- predict(object, xu)
  res <- ru[match(x, xu), ]
  copy_attrs <- c("class", "knots", "Boundary.knots", "intercept")
  attributes(res)[copy_attrs] <- attributes(ru)[copy_attrs]
  res
}

#' @export
prep.step_ns <- function(x, training, info = NULL, ...) {
  col_names <- eval_select_recipes(x$terms, training, info)

  check_type(training[, col_names])

  opt <- x$options
  opt$df <- x$deg_free
  obj <- lapply(training[, col_names], ns_statistics, opt)
  for (i in seq(along.with = col_names))
    attr(obj[[i]], "var") <- col_names[i]
  step_ns_new(
    terms = x$terms,
    role = x$role,
    trained = TRUE,
    deg_free = x$deg_free,
    objects = obj,
    options = x$options,
    skip = x$skip,
    id = x$id
  )
}

#' @export
bake.step_ns <- function(object, new_data, ...) {
  ## pre-allocate a matrix for the basis functions.
  new_cols <- vapply(object$objects, ncol, c(int = 1L))
  ns_values <-
    matrix(NA, nrow = nrow(new_data), ncol = sum(new_cols))
  colnames(ns_values) <- rep("", sum(new_cols))
  strt <- 1
  for (i in names(object$objects)) {
    cols <- (strt):(strt + new_cols[i] - 1)
    orig_var <- attr(object$objects[[i]], "var")
    ns_values[, cols] <-
      ns_predict(object$objects[[i]], getElement(new_data, i))
    new_names <-
      paste(orig_var, "ns", names0(new_cols[i], ""), sep = "_")
    colnames(ns_values)[cols] <- new_names
    strt <- max(cols) + 1
    new_data[, orig_var] <- NULL
  }
  new_data <- bind_cols(new_data, as_tibble(ns_values))
  if (!is_tibble(new_data))
    new_data <- as_tibble(new_data)
  new_data
}


print.step_ns <-
  function(x, width = max(20, options()$width - 28), ...) {
    cat("Natural Splines on ")
    printer(names(x$objects), x$terms, x$trained, width = width)
    invisible(x)
  }

#' @rdname tidy.recipe
#' @param x A `step_ns` object.
#' @export
tidy.step_ns <- function(x, ...) {
  if (is_trained(x)) {
    cols <- tibble(terms = names(x$objects))
  } else {
    cols <- sel2char(x$terms)
  }
  res <- expand.grid(terms = cols, stringsAsFactors = FALSE)
  res$id <- x$id
  as_tibble(res)
}



#' @rdname tunable.step
#' @export
tunable.step_ns <- function(x, ...) {
  tibble::tibble(
    name = c("deg_free"),
    call_info = list(
      list(pkg = "dials", fun = "spline_degree", range = c(1L, 15L))
    ),
    source = "recipe",
    component = "step_ns",
    component_id = x$id
  )
}
