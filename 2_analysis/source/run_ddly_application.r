# =============================================================================
# DDLY (2018) bank volatility — two-stage application (Issue #5)
#
# Reads the cleaned log-volatility series from 1_data/output/ddly_clean.rds,
# subsets to a configurable set of series, and runs the two-stage pipeline.
# Saves diagnostics (Stage-1 traces, convergence summary), the PIP and plinks
# matrices, and a side-by-side network figure ranked by region.
#
# Configuration (env vars):
#   DDLY_MODE = smoke    -> p ~ 30 (top-25 banks by assets + 5 reference bonds)
#   DDLY_MODE = mid      -> p ~ 50 (top-40 banks + all 10 bonds)  [default]
#   DDLY_MODE = full     -> p = 106 (all banks + all bonds)
#   DDLY_LAMBDA = 0.5    -> single lambda value used by this run
#   DDLY_SAEM_ITER       -> SAEM iterations (default depends on mode)
#   DDLY_BD_ITER         -> Stage-2 BDgraph iterations (default 4000)
#
# Outputs (filenames embed the mode and lambda, e.g. *_full_lambda0.50.*):
#   2_analysis/output/tables/ddly_results_<mode>_lambda<lambda>.rds
#   2_analysis/output/figures/ddly_traces_<mode>_lambda<lambda>.pdf
#   2_analysis/output/figures/ddly_network_<mode>_lambda<lambda>.pdf
#   2_analysis/output/tables/ddly_summary_<mode>_lambda<lambda>.tex
# =============================================================================

suppressPackageStartupMessages({
  library(igraph)
  # gRbase is required by saem_mcmc.R (via gRbase::junction_tree); not loaded
  # here so the script can start in environments where gRbase is not installed,
  # falling through to a clear `gRbase::junction_tree` error at first call.
  library(MASS)
  library(BDgraph)
  library(ggplot2)
  library(dplyr)
  library(tidyr)
  library(tibble)
})

source("../../utils/analysis_tools/saem_mcmc.R")
source("../../utils/analysis_tools/two_stage.R")

set.seed(20260427)

# ---- Configuration ---------------------------------------------------------
mode    <- tolower(Sys.getenv("DDLY_MODE", unset = "mid"))
lambda  <- as.numeric(Sys.getenv("DDLY_LAMBDA", unset = "0.5"))
n_banks <- switch(mode, smoke = 25L, mid = 40L, full = 96L,
                  stop("DDLY_MODE must be 'smoke', 'mid', or 'full'"))
n_bonds <- switch(mode, smoke = 5L,  mid = 10L, full = 10L)

saem_iter <- as.integer(Sys.getenv(
  "DDLY_SAEM_ITER",
  unset = switch(mode, smoke = "2000", mid = "5000", full = "8000")
))
bd_iter   <- as.integer(Sys.getenv("DDLY_BD_ITER", unset = "4000"))
bd_burnin <- bd_iter %/% 4L

cat(sprintf("[ddly] mode=%s  p=%d (%d banks + %d bonds)  lambda=%.2f\n",
            mode, n_banks + n_bonds, n_banks, n_bonds, lambda))
cat(sprintf("[ddly] saem_iter=%d  bd_iter=%d (burnin=%d)\n",
            saem_iter, bd_iter, bd_burnin))

# ---- Load + subset data ----------------------------------------------------
data <- readRDS("../../1_data/output/ddly_clean.rds")
Y_full      <- data$Y
metadata    <- data$metadata

bank_idx <- metadata$column_idx[metadata$asset_class == "Bank stock"]
bond_idx <- metadata$column_idx[metadata$asset_class == "Sovereign bond"]

# Banks are already ordered by total assets descending; bonds in fixed order.
sel_idx <- c(head(bank_idx, n_banks), head(bond_idx, n_bonds))
Y       <- Y_full[, sel_idx]
md      <- metadata[sel_idx, ]
md$column_idx <- seq_len(nrow(md))   # renumber within the subset
colnames(Y) <- md$ticker

p <- ncol(Y); n <- nrow(Y)
cat(sprintf("[ddly] n=%d obs, p=%d series\n", n, p))

# ---- Stage 1 + Stage 2 -----------------------------------------------------
cat("[ddly] Running two-stage at lambda =", lambda, "...\n")
t0 <- proc.time()
ts <- run_two_stage(
  Y      = Y,
  lambda = lambda,
  r0     = 0.2,
  stage1_args = list(n_iter = saem_iter, M = 5, data_prop = TRUE,
                     verbose = max(50L, saem_iter %/% 20L)),
  stage2_args = list(iter = bd_iter, burnin = bd_burnin, verbose = FALSE),
  verbose = TRUE
)
elapsed_min <- as.numeric((proc.time() - t0)["elapsed"]) / 60
cat(sprintf("[ddly] two-stage done in %.1f min\n", elapsed_min))

stage1 <- ts$stage1
pip    <- ts$pip_hat
plinks <- ts$plinks

# ---- Stage-1 convergence diagnostics ---------------------------------------
# Sentinels used below:
#   - discard the first 50% of SAEM iterations and summarize the retained tail
#   - assess hat_tau / hat_r stability via coefficient of variation on that tail
#   - report simple log-likelihood drift over that tail
# Note: no effective-sample-size diagnostic is computed here.

burn <- floor(0.5 * saem_iter)
keep <- (burn + 1):saem_iter

tau_tail   <- stage1$history$tau[keep]
r_tail     <- stage1$history$r[keep]
ll_tail    <- stage1$history$loglik[keep]
edges_tail <- stage1$history$edges[keep]

tau_cv  <- sd(tau_tail) / abs(mean(tau_tail))
r_cv    <- sd(r_tail)   / max(abs(mean(r_tail)), 1e-6)
ll_drift <- diff(range(ll_tail)) / abs(mean(ll_tail))

cat("\n=== Stage-1 convergence summary ===\n")
cat(sprintf("  tau:   mean = %.3f, CV (last %d) = %.4f\n",
            mean(tau_tail), length(keep), tau_cv))
cat(sprintf("  r:     mean = %.4f, CV (last %d) = %.4f\n",
            mean(r_tail), length(keep), r_cv))
cat(sprintf("  loglik: mean = %.2f, drift = %.4f\n",
            mean(ll_tail), ll_drift))
cat(sprintf("  edges: mean = %.1f / max = %d\n",
            mean(edges_tail), p * (p - 1) / 2))

if (tau_cv > 0.05) warning("[ddly] tau CV > 5%: Stage-1 may not have converged.")
if (r_cv > 0.05) warning("[ddly] r CV > 5%: Stage-1 may not have converged.")
if (ll_drift > 0.05) warning("[ddly] loglik drifting: extend burn-in or saem_iter.")

# ---- Stage-2 sanity --------------------------------------------------------
stopifnot(
  isSymmetric(plinks, tol = 1e-9),
  all(plinks >= -1e-9),
  all(plinks <= 1 + 1e-9)
)
stage1_edges <- sum(pip > 0.5)    / 2  # upper triangle only
stage2_edges <- sum(plinks > 0.5) / 2

cat("\n=== Stage-2 sanity ===\n")
cat(sprintf("  Stage-1 edges (PIP > 0.5): %d  (%.1f%% of %d possible)\n",
            stage1_edges, 100 * stage1_edges / (p * (p - 1) / 2),
            p * (p - 1) / 2))
cat(sprintf("  Stage-2 edges (plinks > 0.5): %d\n", stage2_edges))

# ---- Persist results -------------------------------------------------------
out_dir_t <- "../output/tables"
out_dir_f <- "../output/figures"
dir.create(out_dir_t, recursive = TRUE, showWarnings = FALSE)
dir.create(out_dir_f, recursive = TRUE, showWarnings = FALSE)

results <- list(
  config = list(mode = mode, lambda = lambda, p = p, n = n,
                saem_iter = saem_iter, bd_iter = bd_iter,
                elapsed_min = elapsed_min),
  metadata = md,
  pip_matrix = pip,
  plinks = plinks,
  stage1_history = stage1$history,
  stage1_params = stage1$params
)
saveRDS(results, file.path(out_dir_t, sprintf("ddly_results_%s_lambda%.2f.rds",
                                              mode, lambda)))
cat(sprintf("\n[write] ddly_results_%s_lambda%.2f.rds\n", mode, lambda))

# ---- Diagnostic figure: Stage-1 traces -------------------------------------
hist_df <- tibble(
  iter   = seq_along(stage1$history$tau),
  tau    = stage1$history$tau,
  r      = stage1$history$r,
  loglik = stage1$history$loglik,
  edges  = stage1$history$edges
) %>%
  pivot_longer(-iter, names_to = "series", values_to = "value")

p_traces <- ggplot(hist_df, aes(x = iter, y = value)) +
  geom_line(color = "#0077BB", linewidth = 0.4) +
  geom_vline(xintercept = burn, linetype = "dashed",
             color = "#BBBBBB", linewidth = 0.4) +
  facet_wrap(~ series, scales = "free_y", nrow = 2) +
  labs(x = "SAEM iteration", y = NULL) +
  theme_minimal(base_size = 11) +
  theme(panel.grid.minor = element_blank(),
        strip.text = element_text(face = "bold"))

ggsave(file.path(out_dir_f, sprintf("ddly_traces_%s_lambda%.2f.pdf",
                                    mode, lambda)),
       p_traces, width = 8, height = 4.5, bg = "transparent",
       device = cairo_pdf)
cat(sprintf("[write] ddly_traces_%s_lambda%.2f.pdf\n", mode, lambda))

# ---- Network figure --------------------------------------------------------
# Build an undirected igraph from Stage-2 plinks > 0.5; color nodes by region.
adj <- (plinks > 0.5) * 1L
diag(adj) <- 0L
g <- graph_from_adjacency_matrix(adj, mode = "undirected")
V(g)$region    <- md$region
V(g)$asset     <- md$asset_class
V(g)$ticker    <- md$ticker
V(g)$bank_name <- md$bank_name
V(g)$short     <- md$short_name

region_levels <- c("US", "Canada", "UK", "Eurozone", "Other Europe",
                   "Asia", "Pacific", "Latin America", "Other EM")
region_colors <- c(US = "#0077BB", Canada = "#4FA3D1",
                   UK = "#EE3377", Eurozone = "#EE7733",
                   `Other Europe` = "#F2A65A", Asia = "#009988",
                   Pacific = "#A8D8AC", `Latin America` = "#CC3311",
                   `Other EM` = "#888888")

set.seed(20260427)
layout_g <- layout_with_fr(g, weights = NULL)

# Label only the most central banks (excluding sovereign bonds from the
# ranking) plus all sovereign bonds. Centrality: degree on the recovered
# graph (Stage-2 plinks > 0.5).
deg <- igraph::degree(g)
deg_for_rank <- deg
deg_for_rank[V(g)$asset == "Sovereign bond"] <- -1L  # bonds excluded from top-N
top_n_label <- 10L
label_idx <- union(
  order(deg_for_rank, decreasing = TRUE)[seq_len(top_n_label)],
  which(V(g)$asset == "Sovereign bond")
)
labels_text <- V(g)$short[label_idx]

# Inline boxed-label helper: draws a thin-padded white rectangle behind
# each label so text contrasts the dense network background. Single text()
# call per label keeps the PDF text layer clean (vs.\ a halo of 16 stacked
# white copies). `pad_x`/`pad_y` are in user-coordinate units.
label_box <- function(x, y, labels, col = "black", bg = "white",
                      border = NA, pad_x = 0.006, pad_y = 0.005,
                      cex = 0.85, font = 2L, ...) {
  for (i in seq_along(labels)) {
    w <- strwidth(labels[i], cex = cex, font = font)
    h <- strheight(labels[i], cex = cex, font = font)
    rect(x[i] - w / 2 - pad_x, y[i] - h / 2 - pad_y,
         x[i] + w / 2 + pad_x, y[i] + h / 2 + pad_y,
         col = bg, border = border)
  }
  text(x, y, labels = labels, col = col, cex = cex, font = font, ...)
}

pdf(file.path(out_dir_f, sprintf("ddly_network_%s_lambda%.2f.pdf",
                                 mode, lambda)),
    width = 14, height = 11)
op <- par(no.readonly = TRUE)
# Two-panel device: 92% height for the network, 8% for the horizontal legend.
layout(matrix(c(1, 2), nrow = 2), heights = c(92, 8))

par(mar = c(0.5, 0.5, 0.5, 0.5))
plot(g, layout = layout_g,
     vertex.size        = ifelse(V(g)$asset == "Sovereign bond", 8, 4),
     vertex.color       = region_colors[V(g)$region],
     vertex.frame.color = "white",
     vertex.label       = NA,
     edge.color         = "#33333330",  # lighter edges so labels pop
     edge.width         = 0.4)

# Reproduce igraph's default per-axis rescale to [-1, 1] so we can place
# label boxes in the same coordinate system as the rendered nodes.
xy_x <- 2 * (layout_g[, 1] - min(layout_g[, 1])) / diff(range(layout_g[, 1])) - 1
xy_y <- 2 * (layout_g[, 2] - min(layout_g[, 2])) / diff(range(layout_g[, 2])) - 1
label_box(x = xy_x[label_idx],
          y = xy_y[label_idx] + 0.035,  # tight offset: label sits beside its node
          labels = labels_text,
          pad_x = 0.004, pad_y = 0.003,
          cex = 0.9, font = 2L)

# Legend panel: empty plot with two horizontal legend() rows.
# 4 entries on top, 5 on bottom, with "Other" categories at the end of the
# bottom row.
par(mar = c(0, 0, 0, 0))
plot.new()
legend_top <- c("US", "Canada", "UK", "Eurozone")
legend_bot <- c("Asia", "Pacific", "Latin America", "Other Europe", "Other EM")
legend(x = 0.5, y = 0.95,
       legend = legend_top, pch = 21, pt.bg = region_colors[legend_top],
       pt.cex = 2.0, horiz = TRUE, bty = "n", cex = 1.3,
       xjust = 0.5, yjust = 1, x.intersp = 0.7)
legend(x = 0.5, y = 0.45,
       legend = legend_bot, pch = 21, pt.bg = region_colors[legend_bot],
       pt.cex = 2.0, horiz = TRUE, bty = "n", cex = 1.3,
       xjust = 0.5, yjust = 1, x.intersp = 0.7)
par(op)
dev.off()
cat(sprintf("[write] ddly_network_%s_lambda%.2f.pdf\n", mode, lambda))

# ---- Region-by-region summary table ----------------------------------------
edge_list <- which(adj == 1L & upper.tri(adj), arr.ind = TRUE)
if (nrow(edge_list) > 0L) {
  edge_tbl <- tibble(
    i_idx = edge_list[, 1],
    j_idx = edge_list[, 2],
    region_i = md$region[edge_list[, 1]],
    region_j = md$region[edge_list[, 2]]
  )
  edge_tbl$pair <- mapply(function(a, b) paste(sort(c(a, b)), collapse = " - "),
                          edge_tbl$region_i, edge_tbl$region_j)
  region_summary <- edge_tbl %>%
    count(pair, name = "edges") %>%
    arrange(desc(edges))
} else {
  region_summary <- tibble(pair = character(0), edges = integer(0))
}

cat("\n=== Edges by region pair (top 10) ===\n")
print(head(region_summary, 10))

# Emit a tiny LaTeX summary table.
tex_lines <- c(
  sprintf("%% Auto-generated by run_ddly_application.r (mode=%s, lambda=%.2f)",
          mode, lambda),
  "\\begin{tabular}{lr}",
  "\\toprule",
  "Region pair & Edges \\\\",
  "\\midrule"
)
for (i in seq_len(min(nrow(region_summary), 10))) {
  tex_lines <- c(tex_lines,
                 sprintf("%s & %d \\\\", region_summary$pair[i],
                         region_summary$edges[i]))
}
tex_lines <- c(tex_lines, "\\bottomrule", "\\end{tabular}")

writeLines(tex_lines,
           file.path(out_dir_t, sprintf("ddly_summary_%s_lambda%.2f.tex",
                                        mode, lambda)))
cat(sprintf("[write] ddly_summary_%s_lambda%.2f.tex\n", mode, lambda))

cat("\n[ddly] DONE.\n")
