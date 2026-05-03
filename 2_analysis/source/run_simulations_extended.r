# =============================================================================
# Extended simulation grid (Section 6 of the paper).
#
# Compares five methods on five topologies (decomposable + non-decomposable)
# at three sizes and four signal strengths, with R Monte Carlo replicates
# per cell:
#
#   p                  in {5, 10, 20}
#   topology           in {chain, star, cycle, erdos_renyi, barabasi_albert}
#   diagonal_strength  in {3, 5, 10, 15}
#   method             in {stage1, bdgraph, two_stage, glasso, npn}
#
# bdgraph is BDgraph at its package default flat prior (g.prior = 0.2),
# without any Stage-1 information transfer. It is the appropriate
# uninformative-prior Stage-2 baseline for the two-stage estimator: any
# gap to two_stage at lambda = 0.5 attributes cleanly to the Stage-1 PIPs
# being mixed in.
#
# Each replicate generates one Y from the topology-implied Gaussian DGP
# and fits all five methods on the SAME data. Metrics: TPR, FPR, MCC,
# Hamming.
#
# Output:
#   ../output/tables/simulation_results_extended.rds      Long-format tibble
#                                                          with all metrics
#                                                          (300 cells x 5 methods).
#   ../output/tables/simulation_table_extended.tex        Headline d=5 slice
#                                                          by topology x p.
#   ../output/tables/simulation_signal_by_topology.tex    Paper-input table:
#                                                          topology x method x d.
#
# Usage:
#   Rscript run_simulations_extended.r            # full grid (~9.5 h on 12 cores)
#   QUICK=1 Rscript run_simulations_extended.r    # 1 size x 1 topo x 1 rep
# =============================================================================

suppressPackageStartupMessages({
  library(igraph)
  library(gRbase)
  library(MASS)
  library(parallel)
  library(BDgraph)
  library(huge)
})

source("../../utils/analysis_tools/saem_mcmc.R")
source("../../utils/analysis_tools/two_stage.R")
source("../../utils/analysis_tools/comparators.R")

set.seed(20260426)

QUICK <- tolower(Sys.getenv("QUICK")) %in% c("1", "true", "yes")

# =============================================================================
# Configuration
# =============================================================================

if (QUICK) {
  cfg <- list(
    p_grid           = c(5),
    topo_grid        = c("cycle"),
    n_replicates     = 1,
    n_obs            = 500,
    saem_iter        = 1000,
    saem_M           = 1,
    bdgraph_iter     = 1000,
    bdgraph_burnin   = 300,
    two_stage_lambda = 0.5,
    two_stage_r0     = 0.2,
    diagonal_grid    = c(5),
    edge_strength    = 1.9,
    seed_base        = 20260426L
  )
} else {
  cfg <- list(
    p_grid           = c(5, 10, 20),
    topo_grid        = c("chain", "star", "cycle", "erdos_renyi", "barabasi_albert"),
    n_replicates     = 5,
    n_obs            = 500,
    saem_iter        = 5000,
    saem_M            = 5,
    bdgraph_iter     = 3000,
    bdgraph_burnin   = 1000,
    two_stage_lambda = 0.5,
    two_stage_r0     = 0.2,
    # Signal-strength sweep (Issue #27). The implied maximum partial
    # correlation is edge_strength / diagonal_strength = 1.9 / d, so the
    # grid {3, 5, 10, 15} covers partial correlations {0.63, 0.38, 0.19,
    # 0.13} from very strong to weak. The headline calibration is d=5
    # (partial corr ~0.38), where EBIC-tuned glasso recovers structure on
    # most topologies. d=15 is the package-example default and lies below
    # the lasso's detection threshold at n=500 for p>=10, so it isolates
    # the Bayesian-vs-frequentist mechanism. Intermediate values trace the
    # transition.
    diagonal_grid    = c(3, 5, 10, 15),
    edge_strength    = 1.9,
    seed_base        = 20260426L,
    headline_diagonal = 5  # which slice fills the LaTeX table that section 6 \input's
  )
}

# =============================================================================
# Per-cell worker: same Y, four methods
# =============================================================================

run_one_cell <- function(p, topology, diagonal_strength, replicate, seed,
                         cfg, cell_idx, n_total) {
  set.seed(seed)

  cat(sprintf("[worker pid=%d] cell %d/%d  (p=%d, %s, d=%d, rep=%d, seed=%d)\n",
              Sys.getpid(), cell_idx, n_total, p, topology,
              diagonal_strength, replicate, seed))

  # --- Generate true graph + data (same Y for all methods in this cell) ----
  G_true   <- generate_true_graph(p, type = topology)
  # Defensive guard against silent-zero regressions (Issue #20).
  stopifnot("generate_true_graph returned an empty graph (silent dispatch fall-through?)"
            = sum(G_true) > 0)
  sim_data <- generate_simulation_data(G_true, n = cfg$n_obs,
                                       diagonal_strength = diagonal_strength,
                                       edge_strength = cfg$edge_strength)
  Y        <- sim_data$Y

  rows <- list()

  # --- Stage 1 + Stage 2 in one shot via run_two_stage ---------------------
  ts <- run_two_stage(
    Y = Y,
    lambda = cfg$two_stage_lambda,
    r0 = cfg$two_stage_r0,
    stage1_args = list(n_iter = cfg$saem_iter, M = cfg$saem_M,
                       data_prop = TRUE, verbose = 0),
    stage2_args = list(iter = cfg$bdgraph_iter, burnin = cfg$bdgraph_burnin,
                       verbose = FALSE),
    verbose = FALSE
  )

  # Trap diagnostic from the Stage-1 SAEM run (Issue #20). NA for non-SAEM
  # methods so the column type stays numeric.
  stage1_frac_empty <- ts$stage1$diagnostics$frac_empty

  G_stage1 <- (ts$pip_hat > 0.5) * 1L
  G_stage2 <- (ts$plinks  > 0.5) * 1L

  base_cols <- function(method, elapsed, frac_empty = NA_real_) {
    data.frame(p = p, topology = topology,
               diagonal_strength = diagonal_strength,
               replicate = replicate,
               method = method, elapsed_sec = elapsed,
               frac_empty = frac_empty)
  }

  # Per-method timings: stage1 = SAEM only; two_stage = SAEM + BDgraph
  # (since the two-stage estimator depends on the Stage-1 PIPs).
  rows$stage1 <- cbind(
    base_cols("stage1", ts$elapsed_stage1, stage1_frac_empty),
    calc_metrics(G_stage1, G_true)
  )
  rows$two_stage <- cbind(
    base_cols("two_stage", ts$elapsed_stage1 + ts$elapsed_stage2,
              stage1_frac_empty),
    calc_metrics(G_stage2, G_true)
  )

  # --- GLASSO --------------------------------------------------------------
  res_glasso <- tryCatch(fit_glasso(Y), error = function(e) NULL)
  if (!is.null(res_glasso)) {
    rows$glasso <- cbind(
      base_cols("glasso", res_glasso$elapsed_sec),
      calc_metrics(res_glasso$G_est, G_true)
    )
  }

  # --- Vanilla BDgraph (g.prior = 0.2 default; no Stage-1 information) -----
  # Fair "no information transfer" baseline for the two-stage estimator.
  # The same Stage-2 sampler runs without any DIP, so any residual gap
  # to two_stage at lambda = 0.5 is the contribution of the Stage-1 PIPs.
  res_bdg <- tryCatch(
    fit_bdgraph(Y, iter = cfg$bdgraph_iter, burnin = cfg$bdgraph_burnin),
    error = function(e) NULL
  )
  if (!is.null(res_bdg)) {
    rows$bdgraph <- cbind(
      base_cols("bdgraph", res_bdg$elapsed_sec),
      calc_metrics(res_bdg$G_est, G_true)
    )
  }

  # --- Nonparanormal -------------------------------------------------------
  res_npn <- tryCatch(fit_npn(Y), error = function(e) NULL)
  if (!is.null(res_npn)) {
    rows$npn <- cbind(
      base_cols("npn", res_npn$elapsed_sec),
      calc_metrics(res_npn$G_est, G_true)
    )
  }

  do.call(rbind, rows)
}

# =============================================================================
# Main: build grid, dispatch, save
# =============================================================================

main <- function() {
  grid <- expand.grid(
    p                 = cfg$p_grid,
    topology          = cfg$topo_grid,
    diagonal_strength = cfg$diagonal_grid,
    replicate         = seq_len(cfg$n_replicates),
    stringsAsFactors  = FALSE
  )
  grid$cell_idx <- seq_len(nrow(grid))
  grid$seed <- cfg$seed_base + grid$cell_idx

  n_cores <- min(nrow(grid), max(1, parallel::detectCores() - 2))
  cat(sprintf("[grid] %d cells (5 methods each = %d method-cells); %d cores\n",
              nrow(grid), 5 * nrow(grid), n_cores))

  t0 <- proc.time()
  results_list <- parallel::mclapply(
    seq_len(nrow(grid)),
    function(i) run_one_cell(p = grid$p[i], topology = grid$topology[i],
                             diagonal_strength = grid$diagonal_strength[i],
                             replicate = grid$replicate[i],
                             seed = grid$seed[i], cfg = cfg,
                             cell_idx = i, n_total = nrow(grid)),
    mc.cores = n_cores, mc.preschedule = FALSE
  )
  elapsed <- (proc.time() - t0)["elapsed"]
  cat(sprintf("\n[grid] complete in %.1f min\n", elapsed / 60))

  results <- do.call(rbind, results_list)
  cat("\n=== Summary (mean MCC by diagonal x topology x method, averaged over p and replicates) ===\n")
  agg <- aggregate(MCC ~ diagonal_strength + topology + method,
                   data = results, FUN = mean)
  print(reshape(agg, idvar = c("diagonal_strength", "topology"),
                timevar = "method", direction = "wide"),
        row.names = FALSE)

  # --- Persist -------------------------------------------------------------
  dir.create("../output/tables", recursive = TRUE, showWarnings = FALSE)
  out_rds <- "../output/tables/simulation_results_extended.rds"
  saveRDS(results, out_rds)
  cat(sprintf("\n[write] %s (%d rows)\n", out_rds, nrow(results)))

  # --- LaTeX table at the headline calibration (diagonal = headline_diagonal)
  # Section 6 of the paper \input's this; the same table includes only the
  # main calibration slice so the prose numbers stay aligned.
  headline_d <- if (!is.null(cfg$headline_diagonal)) cfg$headline_diagonal
                else cfg$diagonal_grid[1]
  headline <- results[results$diagonal_strength == headline_d, ]
  agg2 <- aggregate(cbind(TPR, FPR, MCC, Hamming) ~ topology + p + method,
                    data = headline, FUN = mean)
  agg2 <- agg2[order(agg2$topology, agg2$p, agg2$method), ]

  write_extended_tex(agg2, "../output/tables/simulation_table_extended.tex")
  cat(sprintf("[write] ../output/tables/simulation_table_extended.tex (diagonal = %d slice)\n",
              headline_d))

  # --- Signal-axis table actually \input'd by the paper (Table in §6).
  # Cells are mean MCC over (p, replicate); rows are (topology, method);
  # columns are diagonal_strength.
  agg3 <- aggregate(MCC ~ topology + method + diagonal_strength,
                    data = results, FUN = mean)
  write_signal_axis_tex(agg3,
                        "../output/tables/simulation_signal_by_topology.tex",
                        d_grid = sort(unique(results$diagonal_strength)))
  cat("[write] ../output/tables/simulation_signal_by_topology.tex\n")
}

# Display name for each topology code; preserves a stable ordering that
# matches the paper's narrative (decomposable first, then non-decomposable).
TOPOLOGY_DISPLAY <- c(
  chain           = "Chain",
  star            = "Star",
  cycle           = "Cycle",
  erdos_renyi     = "Erd\\H{o}s--R\\'enyi",
  barabasi_albert = "Barab\\'asi--Albert"
)

# Compact LaTeX table: rows = (topology, p), cols = method, cell = MCC.
# Method ordering reflects the paper's narrative: SAEM-MCMC stage 1 alone,
# then BDgraph (vanilla, no Stage-1 information), then two-stage (DIP),
# then frequentist baselines.
write_extended_tex <- function(agg, path) {
  methods <- c("stage1", "bdgraph", "two_stage", "glasso", "npn")

  pivot <- reshape(agg[, c("topology", "p", "method", "MCC")],
                   idvar = c("topology", "p"), timevar = "method",
                   direction = "wide")
  pivot_cols <- paste0("MCC.", methods)
  for (col in pivot_cols) if (!col %in% names(pivot)) pivot[[col]] <- NA_real_
  pivot <- pivot[, c("topology", "p", pivot_cols)]

  # Order topologies by the paper-narrative order, then by p.
  topo_order <- intersect(names(TOPOLOGY_DISPLAY), unique(pivot$topology))
  pivot <- pivot[order(match(pivot$topology, topo_order), pivot$p), ]

  fmt <- function(x) ifelse(is.na(x), "--", sprintf("%.2f", x))
  display <- function(t) {
    out <- TOPOLOGY_DISPLAY[t]
    out[is.na(out)] <- t[is.na(out)]
    unname(out)
  }

  lines <- c(
    "% Auto-generated by run_simulations_extended.r --- do not edit by hand.",
    "\\begin{tabular}{llrrrrr}",
    "\\toprule",
    "Topology & $p$ & Stage-1 & BDMCMC & Two-stage & GLASSO & NPN \\\\",
    "\\midrule"
  )
  for (i in seq_len(nrow(pivot))) {
    r <- pivot[i, ]
    lines <- c(lines, sprintf("%s & %d & %s & %s & %s & %s & %s \\\\",
                               display(r$topology), r$p,
                               fmt(r$MCC.stage1), fmt(r$MCC.bdgraph),
                               fmt(r$MCC.two_stage),
                               fmt(r$MCC.glasso), fmt(r$MCC.npn)))
  }
  lines <- c(lines, "\\bottomrule", "\\end{tabular}")
  writeLines(lines, path)
}

# Signal-axis table inputted by §6: rows are (topology, method), columns
# are diagonal_strength. Cells are mean MCC over p and replicates.
# Top header shows d values, second header shows implied rho_max ≈ 1.9 / d.
write_signal_axis_tex <- function(agg, path, d_grid) {
  methods       <- c("stage1", "bdgraph", "two_stage", "glasso", "npn")
  method_labels <- c(stage1 = "Stage-1", bdgraph = "BDMCMC",
                     two_stage = "Two-stage", glasso = "GLASSO", npn = "NPN")
  topo_order    <- intersect(names(TOPOLOGY_DISPLAY), unique(agg$topology))

  fmt <- function(x) ifelse(is.na(x), "--", sprintf("%.2f", x))

  d_header <- paste0("$d=", d_grid, "$", collapse = " & ")
  rho_header <- paste0(sprintf("($\\rho_{\\max}\\!\\approx\\!%.2f$)",
                                round(1.9 / d_grid, 2)),
                       collapse = " & ")
  col_spec <- paste0("ll", paste(rep("r", length(d_grid)), collapse = ""))

  lines <- c(
    "% Auto-generated by run_simulations_extended.r --- do not edit by hand.",
    sprintf("\\begin{tabular}{%s}", col_spec),
    "\\toprule",
    paste0("Topology & Method & ", d_header, " \\\\"),
    paste0(" & & ", rho_header, " \\\\"),
    "\\midrule"
  )
  for (ti in seq_along(topo_order)) {
    topo <- topo_order[ti]
    for (mi in seq_along(methods)) {
      m <- methods[mi]
      vals <- sapply(d_grid, function(d) {
        v <- agg$MCC[agg$topology == topo &
                     agg$method == m &
                     agg$diagonal_strength == d]
        if (length(v) == 0) NA_real_ else v
      })
      topo_cell <- if (mi == 1) TOPOLOGY_DISPLAY[topo] else ""
      cells <- paste(sapply(vals, fmt), collapse = " & ")
      lines <- c(lines, sprintf("%s & %s & %s \\\\",
                                 topo_cell, method_labels[m], cells))
    }
    if (ti < length(topo_order)) lines <- c(lines, "\\midrule")
  }
  lines <- c(lines, "\\bottomrule", "\\end{tabular}")
  writeLines(lines, path)
}

main()
