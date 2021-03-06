#' @import methods
NULL

rex::register_shortcuts("covr")
#' calculate the coverage on an environment after evaluating some expressions.
#'
#' This function uses non_standard evaluation so is best used in interactive
#' sessions.
#' @param env the environment to take function definitions from
#' @param ... one or more expressions to be evaluated.
#' @param enc The enclosing environment from which the expressions should be
#' evaluated
#' @export
environment_coverage <- function(env, ..., enc = parent.frame()) {
  exprs <- dots(...)
  environment_coverage_(env, exprs, enc = enc)
}

#' calculate the coverage on an environment after evaluating some expressions.
#'
#' This function does not use non_standard evaluation so is more appropriate
#' for use in other functions.
#' @inheritParams environment_coverage
#' @param exprs a list of parsed expressions to be evaluated.
#' @export
environment_coverage_ <- function(env, exprs, enc = parent.frame()) {
  clear_counters()

  replacements <-
    c(replacements_S4(env),
      Filter(Negate(is.null), lapply(ls(env, all.names = TRUE), replacement, env = env))
    )

  on.exit(lapply(replacements, reset), add = TRUE)

  lapply(replacements, replace)

  for (expr in exprs) {
    eval(expr, enc)
  }

  res <- as.list(.counters)
  clear_counters()

  class(res) <- "coverage"

  res
}

#' Calculate test coverage for specific function.
#'
#' @param fun name of the function.
#' @param env environment the function is defined in.
#' @param ... expressions to run.
#' @param enc the enclosing environment which to run the expressions.
#' @export
function_coverage <- function(fun, ..., env = NULL, enc = parent.frame()) {

  exprs <- dots(...)

  clear_counters()

  replacement <- if (!is.null(env)) {
    replacement(fun, env)
  } else {
    replacement(fun)
  }

  on.exit(reset(replacement), add = TRUE)

  replace(replacement)

  for (expr in exprs) {
    eval(expr, enc)
  }

  res <- as.list(.counters)
  clear_counters()

  res <- lapply(res, set_display_name, path = NULL)
  class(res) <- "coverage"

  res
}

#' Calculate test coverage for a package
#'
#' @param path file path to the package
#' @param ... extra expressions to run
#' @param type run the package \sQuote{test}, \sQuote{vignette},
#' \sQuote{example}, \sQuote{all}, or \sQuote{none}. The default is
#' \sQuote{test}.
#' @param relative_path whether to output the paths as relative or absolute
#' paths.
#' @param quiet whether to load and compile the package quietly
#' @param clean whether to clean temporary output files after running.
#' @param exclusions a named list of files with the lines to exclude from each file.
#' @param exclude_pattern a search pattern to look for in the source to exclude a particular line.
#' @param exclude_start a search pattern to look for in the source to start an exclude block.
#' @param exclude_end a search pattern to look for in the source to stop an exclude block.
#' @export
package_coverage <- function(path = ".",
                             ...,
                             type = c("test", "vignette", "example", "all", "none"),
                             relative_path = TRUE,
                             quiet = TRUE,
                             clean = TRUE,
                             exclusions = NULL,
                             exclude_pattern = options("covr.exclude_pattern"),
                             exclude_start = options("covr.exclude_start"),
                             exclude_end = options("covr.exclude_end")
                             ) {
  type <- match.arg(type)

  if (type == "all") {
    called_args <- as.list(match.call())[-1]

    # remove the type
    called_args$type <- NULL
    res <- list(
                do.call(Recall, c(called_args, type = "test")),
                do.call(Recall, c(called_args, type = "vignette")),
                do.call(Recall, c(called_args, type = "example"))
                )
    class(res) <- "coverages"
    return(res)
  }

  pkg <- devtools::as.package(path)

  if (!file.exists(path)) {
    stop(sQuote(path), " does not exist!", call. = FALSE)
  }


  dots <- dots(...)

  sources <- sources(path)

  tmp_lib <- tempdir()

  # if there are compiled components to a package we have to run in a subprocess
  if (length(sources) > 0) {

    with_makevars(
      c(CFLAGS = "-g -O0 -fprofile-arcs -ftest-coverage",
        CXXFLAGS = "-g -O0 -fprofile-arcs -ftest-coverage",
        FFLAGS = "-g -O0 -fprofile-arcs -ftest-coverage",
        FCFLAGS = "-g -O0 -fprofile-arcs -ftest-coverage",
        LDFLAGS = "--coverage"), {
        subprocess(
          clean = clean,
          quiet = quiet,
          coverage <- run_tests(pkg, tmp_lib, dots, type, quiet)
          )
      })

    coverage <- c(coverage, run_gcov(path, sources, quiet))

    if (isTRUE(clean)) {
      devtools::clean_dll(path)
      clear_gcov(path)
    }
  } else {
    coverage <- run_tests(pkg, tmp_lib, dots, type, quiet)
  }

  coverage <- lapply(coverage, set_display_name, path = if (isTRUE(relative_path)) path else NULL)

  attr(coverage, "type") <- type
  class(coverage) <- "coverage"

  # These BasicClasses are functions from the method package
  coverage <- coverage[display_name(coverage) != "./R/BasicClasses.R"]

  exclude(coverage,
    exclusions = exclusions,
    exclude_pattern = exclude_pattern,
    exclude_start = exclude_start,
    exclude_end = exclude_end
  )
}

set_display_name <- function(x, path = NULL) {
  name <- normalizePath(getSrcFilename(x$srcref, full.names = TRUE), mustWork = FALSE)
  src_file <- attr(x$srcref, "srcfile")
  if (is.null(display_name(src_file))) {
    display_name(src_file) <-
      if (!is.null(path)) {
        rex::re_substitutes(name, rex::rex(normalizePath(path, mustWork = FALSE), "/"), "")
      } else {
        name
      }
  }
  class(x) <- "expression_coverage"
  x
}

run_tests <- function(pkg, tmp_lib, dots, type, quiet) {
  testing_dir <- test_directory(pkg$path)

  devtools::install_deps(pkg, dependencies = TRUE)
  RCMD("INSTALL",
                 options = c(pkg$path,
                             "--no-docs",
                             "--no-multiarch",
                             "--no-demo",
                             "--preclean",
                             "--with-keep.source",
                             "--no-byte-compile",
                             "--no-test-load",
                             "-l",
                             tmp_lib),
                  quiet = quiet)

  with_lib(tmp_lib,
                     library(pkg$package,
                             character.only = TRUE))

  ns_env <- asNamespace(pkg$package)
  env <- new.env(parent = ns_env) # nolint
  vignette_dir <- file.path(pkg$path, "vignettes")
  example_dir <- file.path(pkg$path, "man")
  args <-
    c(dots,
      if (type == "test" && file.exists(testing_dir)) {
        bquote(try(source_dir(path = .(testing_dir), env = .(env), quiet = .(quiet))))
      } else if (type == "vignette" && file.exists(vignette_dir)) {
        lapply(dir(vignette_dir, pattern = rex::rex(".", one_of("R", "r"), or("nw", "md")), full.names = TRUE),
          function(file) {
            out_file <- tempfile(fileext = ".R")
            knitr::knit(input = file, output = out_file, tangle = TRUE)
            bquote(source_from_dir(.(out_file), .(vignette_dir), .(env), quiet = .(quiet)))
          })
      } else if (type == "example" && file.exists(example_dir)) {
        lapply(dir(example_dir, pattern = rex::rex(".Rd"), full.names = TRUE),
          function(file) {
            out_file <- tempfile(fileext = ".R")
            ex <- example_code(file)
            cat(ex, file = out_file)
            bquote(source_from_dir(.(out_file), NULL, .(env), chdir = FALSE, quiet = .(quiet)))
          })
      }
    )
  enc <- environment()
  environment_coverage_(ns_env, args, enc)
}
