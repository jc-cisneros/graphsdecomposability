# =============================================================================
# Two-Stage Pipeline: SAEM-MCMC (decomposable) -> DIP -> BDgraph (general)
# =============================================================================
#
# Stage 1 runs SAEM-MCMC over decomposable graphs
# and returns the posterior edge inclusion probability (PIP) matrix. Stage 2
# feeds those PIPs into BDgraph through a Decomposable-Informed Prior (DIP):
#
#   p_{ij} = lambda * pip_hat_{ij} + (1 - lambda) * r_0
#
# Using the full PIP matrix (rather than the modal triangulation) preserves
# the posterior ambiguity that Niu, Pati & Mallick (2020) identify: fill
# edges of competing minimal triangulations carry PIPs near 1/2, and the
# Stage-2 data arbitrates.
# =============================================================================

if (!exists("run_saem_mcmc")) {
  stop("two_stage.R requires run_saem_mcmc(). Source saem_mcmc.R first:\n",
       "  source('utils/analysis_tools/saem_mcmc.R')\n",
       "  source('utils/analysis_tools/two_stage.R')")
}

#' Construct the Decomposable-Informed Prior matrix.
#'
#' @param pip_hat p x p symmetric matrix of Stage-1 posterior edge inclusion
#'        probabilities, in [0, 1]. Diagonal is ignored.
#' @param lambda  numeric in [0, 1]. Mixing weight on the Stage-1 information.
#'        lambda = 0 collapses to a flat prior r_0; lambda = 1 uses pip_hat
#'        directly (so that Stage-1 zeros fully exclude edges from Stage 2).
#' @param r0      numeric in (0, 1). Reference / uninformative edge probability.
#' @return p x p symmetric matrix with zero diagonal, suitable for
#'         `BDgraph::bdgraph(g.prior = .)`.
make_dip <- function(pip_hat, lambda, r0 = 0.5) {
  stopifnot(is.matrix(pip_hat), nrow(pip_hat) == ncol(pip_hat))
  stopifnot(lambda >= 0, lambda <= 1, r0 >= 0, r0 <= 1)
  if (max(abs(pip_hat - t(pip_hat))) > 1e-10) {
    stop("pip_hat must be symmetric.")
  }

  p_ij <- lambda * pip_hat + (1 - lambda) * r0
  diag(p_ij) <- 0
  p_ij
}

#' Run the two-stage pipeline: SAEM-MCMC followed by BDgraph with DIP.
#'
#' @param Y           n x p data matrix.
#' @param lambda      numeric in [0, 1]. Mixing weight for the DIP.
#' @param r0          numeric in (0, 1). Flat reference prior probability.
#' @param stage1_args list of arguments forwarded to `run_saem_mcmc()`.
#'                    See `?run_saem_mcmc` for available arguments.
#' @param stage2_args list of arguments forwarded to `BDgraph::bdgraph()`.
#'                    See `?BDgraph::bdgraph`. The `data` and `g.prior`
#'                    arguments are set by this function and cannot be
#'                    overridden through `stage2_args`.
#' @param verbose     Logical. Print stage progress.
#' @return Named list:
#'   * `stage1`           : output of `run_saem_mcmc()` (Stage-1 posterior over D_p)
#'   * `stage2`           : output of `BDgraph::bdgraph()` (Stage-2 posterior over G)
#'   * `pip_hat`          : Stage-1 PIP matrix (convenience handle)
#'   * `dip`              : the p x p DIP matrix used as `g.prior` in Stage 2
#'   * `plinks`           : Stage-2 posterior edge probabilities (full p x p)
#'   * `lambda`, `r0`     : mixing weight and reference probability used
#'   * `elapsed_stage1`,
#'     `elapsed_stage2`   : wall-clock seconds per stage (excluding DIP
#'                          construction, which is negligible)
run_two_stage <- function(Y, lambda, r0 = 0.5,
                          stage1_args = list(),
                          stage2_args = list(),
                          verbose = TRUE) {

  if (!requireNamespace("BDgraph", quietly = TRUE)) {
    stop("BDgraph is required. Install via the GraphLearning environment ",
         "(see `environment.yml` and `setup.sh`).")
  }

  # ---- Stage 1 ------------------------------------------------------------
  if (verbose) message("[two_stage] Stage 1: SAEM-MCMC on decomposable graphs...")
  stage1_call <- c(list(Y = Y), stage1_args)
  t0_stage1 <- proc.time()
  stage1 <- do.call(run_saem_mcmc, stage1_call)
  elapsed_stage1 <- as.numeric((proc.time() - t0_stage1)["elapsed"])
  pip_hat <- stage1$pip_matrix

  # ---- DIP construction ---------------------------------------------------
  dip <- make_dip(pip_hat, lambda = lambda, r0 = r0)

  # ---- Stage 2 ------------------------------------------------------------
  if (verbose) {
    message(sprintf("[two_stage] Stage 2: BDgraph with DIP (lambda=%.2f, r0=%.2f)...",
                    lambda, r0))
  }
  user_keys <- names(stage2_args)
  blocked <- intersect(user_keys, c("data", "g.prior"))
  if (length(blocked) > 0) {
    stop("stage2_args may not set: ", paste(blocked, collapse = ", "),
         " (these are managed by run_two_stage).")
  }
  stage2_call <- c(list(data = Y, g.prior = dip), stage2_args)
  t0_stage2 <- proc.time()
  stage2 <- do.call(BDgraph::bdgraph, stage2_call)
  elapsed_stage2 <- as.numeric((proc.time() - t0_stage2)["elapsed"])

  # Make plinks fully symmetric (BDgraph fills upper triangle only)
  plinks <- BDgraph::plinks(stage2)
  plinks <- plinks + t(plinks)
  if (!is.null(colnames(Y))) {
    colnames(plinks) <- rownames(plinks) <- colnames(Y)
  }

  list(
    stage1          = stage1,
    stage2          = stage2,
    pip_hat         = pip_hat,
    dip             = dip,
    plinks          = plinks,
    lambda          = lambda,
    r0              = r0,
    elapsed_stage1  = elapsed_stage1,
    elapsed_stage2  = elapsed_stage2
  )
}
