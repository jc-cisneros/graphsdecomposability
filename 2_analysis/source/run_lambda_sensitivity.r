# =============================================================================
# Lambda Sensitivity (Issue #4)
#
# Sweeps the DIP mixing weight lambda over [0, 1] on a representative simulation
# scenario. For each (topology, replicate) we run Stage-1 ONCE and reuse the
# resulting PIP matrix across all lambda values; only Stage-2 BDgraph is rerun.
#
# Output:
#   ../output/tables/lambda_sensitivity.rds   (long-format)
#   ../output/figures/lambda_sensitivity.pdf  (MCC vs lambda by topology)
#
# Usage:
#   Rscript run_lambda_sensitivity.r              # full sweep (~25 min, 10 cores)
#   QUICK=1 Rscript run_lambda_sensitivity.r      # 1 topology, 1 rep, 3 lambdas
# =============================================================================

suppressPackageStartupMessages({
  library(igraph)
  library(gRbase)
  library(MASS)
  library(parallel)
  library(BDgraph)
  library(ggplot2)
})

source("../../utils/analysis_tools/saem_mcmc.R")
source("../../utils/analysis_tools/two_stage.R")

set.seed(20260427)

QUICK <- tolower(Sys.getenv("QUICK")) %in% c("1", "true", "yes")

# Okabe-Ito-derived palette per project conventions (.agents/rules/r-code-conventions.md)
PALETTE_JSLAB <- c("#0077BB", "#EE3377", "#009988", "#EE7733", "#228833", "#CC3311")
NEUTRAL_GRAY  <- "#BBBBBB"

# =============================================================================
# Configuration
# =============================================================================

if (QUICK) {
  cfg <- list(
    p             = 10,
    n_obs         = 500,
    topologies    = c("cycle"),
    n_replicates  = 1,
    lambda_grid   = c(0.0, 0.5, 1.0),
    saem_iter     = 800,
    saem_M        = 1,
    bdgraph_iter  = 800,
    bdgraph_burnin = 200,
    r0            = 0.2,        # nests off-the-shelf BDgraph at lambda = 0
    seed_base     = 20260427L
  )
} else {
  cfg <- list(
    p             = 10,
    n_obs         = 500,
    topologies    = c("chain", "cycle", "erdos_renyi"),
    n_replicates  = 5,
    lambda_grid   = seq(0, 1, by = 0.1),  # 11 values
    saem_iter     = 3000,
    saem_M        = 5,
    bdgraph_iter  = 2000,
    bdgraph_burnin = 500,
    r0            = 0.2,        # nests off-the-shelf BDgraph at lambda = 0
    seed_base     = 20260427L
  )
}

# =============================================================================
# Worker: per (topology, replicate), run Stage 1 once, sweep lambda
# =============================================================================

run_one_unit <- function(topology, replicate, seed, cfg) {
  set.seed(seed)
  cat(sprintf("[worker pid=%d] (%s, rep=%d, seed=%d) Stage-1...\n",
              Sys.getpid(), topology, replicate, seed))

  G_true <- generate_true_graph(cfg$p, type = topology)
  stopifnot("generate_true_graph returned an empty graph (silent dispatch fall-through?)"
            = sum(G_true) > 0)
  Y      <- generate_simulation_data(G_true, n = cfg$n_obs)$Y

  t0 <- proc.time()
  stage1 <- run_saem_mcmc(Y, n_iter = cfg$saem_iter, M = cfg$saem_M,
                          data_prop = TRUE, verbose = 0)
  pip_hat <- stage1$pip_matrix
  s1_elapsed <- as.numeric((proc.time() - t0)["elapsed"])

  G_stage1 <- (pip_hat > 0.5) * 1L
  m_stage1 <- calc_metrics(G_stage1, G_true)

  rows <- list()
  for (lambda in cfg$lambda_grid) {
    dip <- make_dip(pip_hat, lambda = lambda, r0 = cfg$r0)

    # Per-(unit, lambda) seed so that each BDgraph fit has its own RNG
    # stream, independent of the lambda_grid ordering. The multiplier
    # 1000 must exceed the max lambda offset (100) to prevent collisions
    # between adjacent (seed, lambda) pairs; numeric arithmetic with
    # modulo avoids 32-bit integer overflow at seeds of order 1e7.
    set.seed(as.integer(
      (as.numeric(seed) * 1000 + round(lambda * 100)) %% .Machine$integer.max
    ))

    t0 <- proc.time()
    fit <- BDgraph::bdgraph(data = Y, g.prior = dip,
                            iter = cfg$bdgraph_iter,
                            burnin = cfg$bdgraph_burnin, verbose = FALSE)
    s2_elapsed <- as.numeric((proc.time() - t0)["elapsed"])

    # plinks() returns the upper triangle only; symmetrize once and reuse.
    plinks_mat <- BDgraph::plinks(fit)
    plinks <- plinks_mat + t(plinks_mat)
    G_stage2 <- (plinks > 0.5) * 1L
    m_stage2 <- calc_metrics(G_stage2, G_true)

    rows[[length(rows) + 1L]] <- data.frame(
      topology    = topology,
      replicate   = replicate,
      lambda      = lambda,
      stage1_TPR  = m_stage1$TPR, stage1_FPR  = m_stage1$FPR,
      stage1_MCC  = m_stage1$MCC, stage1_Hamming = m_stage1$Hamming,
      stage2_TPR  = m_stage2$TPR, stage2_FPR  = m_stage2$FPR,
      stage2_MCC  = m_stage2$MCC, stage2_Hamming = m_stage2$Hamming,
      s1_elapsed  = s1_elapsed,
      s2_elapsed  = s2_elapsed
    )
  }
  do.call(rbind, rows)
}

# =============================================================================
# Main: dispatch (topology x replicate) units, save, plot
# =============================================================================

main <- function() {
  units <- expand.grid(
    topology  = cfg$topologies,
    replicate = seq_len(cfg$n_replicates),
    stringsAsFactors = FALSE
  )
  units$seed <- cfg$seed_base + seq_len(nrow(units))

  n_cores <- min(nrow(units), max(1, parallel::detectCores() - 2))
  cat(sprintf("[grid] %d (topology, replicate) units x %d lambdas; %d cores\n",
              nrow(units), length(cfg$lambda_grid), n_cores))

  t0 <- proc.time()
  results_list <- parallel::mclapply(
    seq_len(nrow(units)),
    function(i) run_one_unit(topology = units$topology[i],
                             replicate = units$replicate[i],
                             seed = units$seed[i], cfg = cfg),
    mc.cores = n_cores, mc.preschedule = FALSE
  )
  elapsed <- (proc.time() - t0)["elapsed"]
  cat(sprintf("[grid] complete in %.1f min\n", elapsed / 60))

  results <- do.call(rbind, results_list)

  cat("\n=== Mean Stage-2 MCC by lambda x topology ===\n")
  print(reshape(
    aggregate(stage2_MCC ~ topology + lambda, data = results, FUN = mean),
    idvar = "topology", timevar = "lambda", direction = "wide"
  ), row.names = FALSE)

  dir.create("../output/tables",  recursive = TRUE, showWarnings = FALSE)
  dir.create("../output/figures", recursive = TRUE, showWarnings = FALSE)

  saveRDS(results, "../output/tables/lambda_sensitivity.rds")
  cat("[write] ../output/tables/lambda_sensitivity.rds\n")

  make_plot(results, "../output/figures/lambda_sensitivity.pdf")
  cat("[write] ../output/figures/lambda_sensitivity.pdf\n")
}

# =============================================================================
# Plot: MCC vs lambda by topology, with Stage-1 baseline as a dashed reference
# =============================================================================

make_plot <- function(results, path) {
  TOPO_DISPLAY <- c(chain = "Chain (decomposable)",
                    cycle = "Cycle (non-decomposable)",
                    erdos_renyi = "Erdős-Rényi (non-decomposable)",
                    barabasi_albert = "Barabási-Albert (non-decomposable)",
                    star = "Star (decomposable)")
  results$topology_disp <- factor(TOPO_DISPLAY[results$topology],
                                  levels = unname(TOPO_DISPLAY))

  # Stage-2 mean and SE per (topology, lambda). safe_se returns 0 when
  # there is only one replicate (e.g. QUICK mode) so the ribbon still
  # renders cleanly instead of dropping NA bounds.
  safe_se <- function(x) if (length(x) <= 1L) 0 else sd(x) / sqrt(length(x))
  agg2 <- aggregate(stage2_MCC ~ topology_disp + lambda, data = results,
                    FUN = function(x) c(mean = mean(x), se = safe_se(x)))
  agg2 <- data.frame(topology_disp = agg2$topology_disp,
                     lambda = agg2$lambda,
                     mean = agg2$stage2_MCC[, "mean"],
                     se   = agg2$stage2_MCC[, "se"])
  agg2$lo <- agg2$mean - agg2$se
  agg2$hi <- agg2$mean + agg2$se

  # Stage-1 baseline: same for all lambdas, average over replicates
  agg1 <- aggregate(stage1_MCC ~ topology_disp, data = unique(
    results[, c("topology_disp", "replicate", "stage1_MCC")]
  ), FUN = mean)

  # Bare-axes figure: title, subtitle, caption, and any other annotations
  # are deliberately omitted so they can be supplied by the LaTeX caption.
  # Y-axis pinned to [0, 1] (the bounds of MCC) so the dashed Stage-1
  # baselines and the Stage-2 curves are visually comparable.
  p <- ggplot(agg2, aes(x = lambda, y = mean, color = topology_disp,
                        fill = topology_disp)) +
    geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.18, color = NA) +
    geom_line(linewidth = 0.9) +
    geom_point(size = 2) +
    geom_hline(data = agg1, aes(yintercept = stage1_MCC,
                                 color = topology_disp),
               linetype = "dashed", linewidth = 0.6, show.legend = FALSE) +
    scale_color_manual(values = PALETTE_JSLAB) +
    scale_fill_manual(values = PALETTE_JSLAB) +
    scale_x_continuous(breaks = seq(0, 1, by = 0.2)) +
    scale_y_continuous(limits = c(0, 1), breaks = seq(0, 1, by = 0.2)) +
    labs(x = expression(lambda), y = "MCC",
         color = NULL, fill = NULL) +
    theme_minimal(base_size = 12) +
    theme(legend.position = "bottom",
          panel.grid.minor = element_blank())

  # cairo_pdf handles Unicode (ő, é) correctly; the default pdf device
  # rendered ő as "." in the legend.
  ggsave(path, p, width = 7.5, height = 4.5, bg = "transparent",
         device = cairo_pdf)
}

main()
