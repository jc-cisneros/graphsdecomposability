# =============================================================================
# Comparators: GLASSO, nonparanormal, and vanilla BDgraph
# =============================================================================
# Wrappers that fit a graph estimator on Y and return a uniform output:
# a binary p x p adjacency matrix and a continuous edge score (for ROC-style
# comparisons).
#
# Methods covered:
#   - graphical lasso (Friedman, Hastie & Tibshirani 2008)
#   - nonparanormal extension (Liu, Lafferty & Wasserman 2009)
#   - vanilla BDgraph (Mohammadi & Wit 2015) at the package's default flat
#     prior g.prior = 0.2; this is the appropriate "no information transfer"
#     baseline for the two-stage procedure. After the r_0 = 0.2 calibration,
#     two-stage at lambda = 0 also reduces to g.prior = 0.2 by construction,
#     so this comparator coincides with two-stage at lambda = 0.
# =============================================================================

#' Fit GLASSO via the `huge` package with EBIC-tuned regularization.
#'
#' @param Y         n x p data matrix.
#' @param ebic_gamma EBIC gamma parameter (default 0.5; gamma=0 is BIC).
#' @return List with:
#'   * `G_est`       : binary p x p adjacency, zero diagonal
#'   * `edge_score`  : |partial correlation| computed from the SELECTED
#'                     precision matrix, on every off-diagonal pair (not
#'                     masked to selected edges). Suitable for ROC-style
#'                     ranking; pairs not selected by EBIC will typically
#'                     have score 0 because their precision entry is
#'                     exactly 0 under graphical lasso, but no masking is
#'                     applied here.
#'   * `method`, `elapsed_sec`, `lambda_hat`
fit_glasso <- function(Y, ebic_gamma = 0.5) {
  if (!requireNamespace("huge", quietly = TRUE)) stop("Package 'huge' not available.")
  t0 <- proc.time()
  path <- huge::huge(Y, method = "glasso", verbose = FALSE)
  sel  <- huge::huge.select(path, criterion = "ebic", ebic.gamma = ebic_gamma,
                            verbose = FALSE)
  elapsed <- as.numeric((proc.time() - t0)["elapsed"])

  Omega_hat <- as.matrix(sel$opt.icov)
  G_est <- (abs(Omega_hat) > 1e-8) * 1L
  diag(G_est) <- 0L

  # |partial correlation| on every pair (not masked). Under glasso the
  # entries shrunk to zero by EBIC will read as zero; the rest carry
  # continuous information for downstream ranking.
  d <- sqrt(pmax(diag(Omega_hat), 1e-12))
  edge_score <- abs(-Omega_hat / outer(d, d))
  diag(edge_score) <- 0

  list(G_est = G_est, edge_score = edge_score,
       method = "glasso", elapsed_sec = elapsed,
       lambda_hat = sel$opt.lambda)
}

#' Fit nonparanormal (npn) GLASSO: marginal-rank-Gaussianize, then GLASSO.
fit_npn <- function(Y, ebic_gamma = 0.5) {
  if (!requireNamespace("huge", quietly = TRUE)) stop("Package 'huge' not available.")
  t0 <- proc.time()
  Y_npn <- huge::huge.npn(Y, npn.func = "shrinkage", verbose = FALSE)
  out <- fit_glasso(Y_npn, ebic_gamma = ebic_gamma)
  out$method <- "npn"
  out$elapsed_sec <- as.numeric((proc.time() - t0)["elapsed"])
  out
}

#' Fit vanilla BDgraph at the package default prior.
#'
#' This is the "no information transfer" baseline for the two-stage
#' procedure. It uses the same Stage-2 sampler as our DIP-augmented version
#' but with `g.prior = 0.2` (BDgraph's documented default), so any gap
#' between this and the two-stage estimator at lambda = 0.5 is attributable
#' to the Stage-1 PIPs being mixed in --- not to switching estimators.
#'
#' @param Y         n x p data matrix.
#' @param iter      MCMC iterations (default 4000).
#' @param burnin    Burn-in iterations (default iter/2).
#' @param g_prior   Prior edge probability (default 0.2; matches both the
#'                  BDgraph package default and our two-stage at lambda = 0
#'                  under the calibrated r_0 = 0.2).
#' @return List with `G_est`, `edge_score` (Stage-2 plinks),
#'         `method`, `elapsed_sec`.
fit_bdgraph <- function(Y, iter = 4000L, burnin = iter %/% 2L,
                        g_prior = 0.2) {
  if (!requireNamespace("BDgraph", quietly = TRUE)) {
    stop("Package 'BDgraph' not available.")
  }
  t0 <- proc.time()
  fit <- BDgraph::bdgraph(data = Y, iter = iter, burnin = burnin,
                          g.prior = g_prior, verbose = FALSE)
  elapsed <- as.numeric((proc.time() - t0)["elapsed"])

  # plinks() returns the upper triangle only; symmetrize.
  plinks_mat <- BDgraph::plinks(fit)
  plinks <- plinks_mat + t(plinks_mat)

  G_est <- (plinks > 0.5) * 1L
  diag(G_est) <- 0L

  list(G_est = G_est, edge_score = plinks,
       method = "bdgraph", elapsed_sec = elapsed,
       g_prior = g_prior)
}
