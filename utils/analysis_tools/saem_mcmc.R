# =============================================================================
# SAEM-MCMC for Bayesian Graphical Model Selection
#
# Implements the Stochastic Approximation EM algorithm with Metropolis-Hastings
# for learning decomposable Gaussian graphical models under the Hyper-Inverse
# Wishart (HIW) prior.
#
# Reference:
#   Donnet, S. & Marin, J.-M. (2012). An empirical Bayes procedure for the
#   selection of Gaussian graphical models. Statistics and Computing, 22(5),
#   1113-1123.
#
# Based on the implementation by Erik Solé Vives (January 2026).
# Optimized with graph-state caching (April 2026) — cliques and separators
# are computed once per graph and passed through the call chain, eliminating
# the ~6× per-iteration recomputation of the original implementation.
#
# Required packages: igraph, gRbase, MASS (for simulations)
# =============================================================================

# =============================================================================
# Graph Utilities
# =============================================================================

# Fast adjacency -> igraph conversion.
# Skips the isSymmetric() check performed by graph_from_adjacency_matrix(),
# which is a profile hotspot (~35% of total time in the un-optimized code).
# Assumes a square numeric 0/1 matrix whose upper triangle encodes the graph.
adj_to_igraph_fast <- function(G) {
  idx <- which(G == 1 & upper.tri(G), arr.ind = TRUE)
  p <- nrow(G)
  if (nrow(idx) == 0) {
    return(igraph::make_empty_graph(n = p, directed = FALSE))
  }
  # Interleave i1,j1,i2,j2,... for igraph::make_graph()
  edges <- c(t(idx))
  igraph::make_graph(edges, n = p, directed = FALSE)
}

# Back-compat wrappers — thin shims over the fast version.
adj_to_igraph <- function(G) adj_to_igraph_fast(G)

is_decomposable <- function(G) {
  igraph::is_chordal(adj_to_igraph_fast(G))$chordal
}

get_cliques <- function(G) {
  lapply(igraph::max_cliques(adj_to_igraph_fast(G)), as.integer)
}

# Why two packages: igraph provides max_cliques + is_chordal (used in the MH
# enumeration hot path), but does not expose junction-tree decomposition with
# explicit separators. gRbase does (`junction_tree()`), but requires a NAMED
# igraph object and produces a list-of-lists whose innermost elements are
# vertex-name characters. This helper bridges the two: stamps integer-string
# names onto the igraph, runs gRbase, and returns separators as integer index
# vectors (matching the index convention used by everything downstream).
#
# Bit-identical to Erik's `get_separators` for all decomposable graphs we
# tested (chain, star, ER, BA at p=10); see Issue #20 audit log
# `quality_reports/saem_mcmc_audit_2026-04-28.md`.
separators_from_igraph <- function(g) {
  igraph::V(g)$name <- as.character(seq_len(igraph::vcount(g)))
  jt <- gRbase::junction_tree(g)
  sep <- jt$separators
  non_empty <- sep[vapply(sep, length, integer(1)) > 0]
  lapply(non_empty, as.numeric)
}

get_separators <- function(G) {
  separators_from_igraph(adj_to_igraph_fast(G))
}

# =============================================================================
# Graph State: bundles a graph with its derived clique/separator sets
# =============================================================================

# Construct a graph-state list. cliques and separators are computed once here,
# then read directly by downstream hot-path functions, avoiding ~6× redundant
# recomputation per SAEM iteration. The optional `add_cache` and `del_cache`
# fields are filled lazily by mh_edges via .get_or_compute_{add,del}() and
# survive any number of subsequent reads (Issue #25 caching layer).
graph_state <- function(G) {
  g <- adj_to_igraph_fast(G)
  cliques <- lapply(igraph::max_cliques(g), as.integer)
  seps <- separators_from_igraph(g)
  list(G = G, igraph = g, cliques = cliques, separators = seps,
       add_cache = NULL, del_cache = NULL)
}

# Lazy populators for the candidate-set caches on a graph_state. The state
# is value-copied on return; the caller (mh_edges → run_saem_mcmc) must
# round-trip the returned gs to keep the cache populated across calls.
.get_or_compute_add <- function(gs) {
  if (is.null(gs$add_cache)) gs$add_cache <- get_addable_edges(gs$G)
  gs
}
.get_or_compute_del <- function(gs) {
  if (is.null(gs$del_cache)) gs$del_cache <- get_deletable_edges(gs$G)
  gs
}

# =============================================================================
# Log Multivariate Gamma Function (numerically stable)
# =============================================================================

log_mv_gamma <- function(a, v) {
  t1 <- (1 / 4) * (v * (v - 1)) * log(pi)
  t2 <- sum(lgamma(a + ((1 - (1:v))) / 2))
  t1 + t2
}

# =============================================================================
# HIW Distribution Functions
# =============================================================================

log_hiw_clique_sep <- function(clsep, delta, Phi) {
  Phi_C <- as.matrix(Phi[clsep, clsep])
  magnitude <- length(clsep)
  coef1 <- (magnitude + delta - 1) / 2
  term1 <- log(det(Phi_C / 2))
  term2 <- log_mv_gamma((magnitude + delta - 1) / 2, magnitude)
  coef1 * term1 - term2
}

# Graph-state variant: uses cached cliques/separators — no recomputation.
log_hiw_norm_gs <- function(gs, delta, Phi) {
  cl <- gs$cliques
  sep <- gs$separators
  t1 <- sum(vapply(cl, function(x) log_hiw_clique_sep(x, delta, Phi), numeric(1)))
  t2 <- if (length(sep) == 0) 0 else
    sum(vapply(sep, function(x) log_hiw_clique_sep(x, delta, Phi), numeric(1)))
  t1 - t2
}

# Back-compat wrapper for raw-matrix callers.
log_hiw_norm <- function(G, delta, Phi) {
  log_hiw_norm_gs(graph_state(G), delta, Phi)
}

log_prior_graph <- function(G, r) {
  kg <- sum(G[upper.tri(G)])
  m <- (ncol(G) * (ncol(G) - 1)) / 2
  kg * log(r) + (m - kg) * log(1 - r)
}

log_post_dist_gs <- function(gs, delta, Phi, r, Sy, n) {
  num <- log_hiw_norm_gs(gs, delta, Phi)
  den <- log_hiw_norm_gs(gs, delta + n, Phi + Sy)
  prior <- log_prior_graph(gs$G, r)
  num - den + prior
}

log_post_dist <- function(G, delta, Phi, r, Sy, n) {
  log_post_dist_gs(graph_state(G), delta, Phi, r, Sy, n)
}

# =============================================================================
# MH Step: Edge Enumeration
# =============================================================================

get_deletable_edges <- function(G) {
  edges <- which(G == 1 & upper.tri(G), arr.ind = TRUE)
  if (nrow(edges) == 0) return(list())

  valid <- list()
  for (k in 1:nrow(edges)) {
    i <- edges[k, 1]
    j <- edges[k, 2]
    G_tmp <- G
    G_tmp[i, j] <- G_tmp[j, i] <- 0
    if (is_decomposable(G_tmp)) {
      valid[[length(valid) + 1]] <- c(i, j)
    }
  }
  valid
}

get_addable_edges <- function(G) {
  non_edges <- which(G == 0 & upper.tri(G), arr.ind = TRUE)
  if (nrow(non_edges) == 0) return(list())

  valid <- list()
  for (t in 1:nrow(non_edges)) {
    i <- non_edges[t, 1]
    j <- non_edges[t, 2]
    G_tmp <- G
    G_tmp[i, j] <- G_tmp[j, i] <- 1
    if (is_decomposable(G_tmp)) {
      valid[[length(valid) + 1]] <- c(i, j)
    }
  }
  valid
}

# =============================================================================
# MH Acceptance Probability — Algorithm 2 (Uniform Proposal)
# =============================================================================

comp_prob <- function(gs_current, gs_prop, move_type, Sy, n, delta, r, Phi,
                      add_current = NULL, del_current = NULL,
                      forward_flipped = FALSE,
                      log_post_current = NULL) {
  # Only the "matching" side is needed: forward-proposal density comes from
  # add_current (add move) or del_current (delete move); reverse-proposal
  # density comes from del_prop (add move) or add_prop (delete move).
  # Each enumeration is O(p^2) decomposability checks, so halving this count
  # halves the cost of the dominant hotspot.
  #
  # Boundary correction (Issue #20, finding F1): when mh_edges had to flip
  # the initial move-type pick (because the matching candidate set was empty
  # — i.e., G_current was empty for "add" or fully connected for "delete"),
  # the forward proposal density is 1/n instead of (1/2)/n, because *both*
  # initial picks of the move type funnel into the same direction. Same logic
  # for the reverse density at G_prop. Each flip contributes ±log(2) to the
  # log Hastings ratio.
  #
  # Why the O(1) edge-count check is sufficient for backward_flipped: the
  # claim is that the only chordal graphs with no decomposable add are the
  # complete graph, and the only chordal graphs with no decomposable delete
  # are the empty graph. Both directions follow from Dirac's simplicial-vertex
  # theorem (1961): every non-complete chordal graph admits at least one
  # chordal augmentation (extend toward the complete chordal closure), and
  # every non-empty chordal graph has a simplicial vertex v whose incident
  # edges can be deleted while preserving chordality (the neighborhood of v
  # in G - (u,v) is still a clique). So `n_add_decomposable = 0 ⟺ G complete`
  # and `n_del_decomposable = 0 ⟺ G empty`, which is what the edge count
  # detects. See Diestel, Graph Theory (5th ed.), §12 for the chordal-graph
  # results.
  m_total <- (ncol(gs_prop$G) * (ncol(gs_prop$G) - 1)) / 2
  e_prop <- sum(gs_prop$G[upper.tri(gs_prop$G)])
  if (move_type == "add") {
    n_add_current <- length(add_current)
    n_del_prop <- length(get_deletable_edges(gs_prop$G))
    log_q_ratio <- log(n_add_current) - log(n_del_prop)
    backward_flipped <- (e_prop == m_total)  # G_prop complete ⟹ add_prop empty
  } else {
    n_del_current <- length(del_current)
    n_add_prop <- length(get_addable_edges(gs_prop$G))
    log_q_ratio <- log(n_del_current) - log(n_add_prop)
    backward_flipped <- (e_prop == 0)         # G_prop empty ⟹ del_prop empty
  }
  if (forward_flipped)  log_q_ratio <- log_q_ratio - log(2)
  if (backward_flipped) log_q_ratio <- log_q_ratio + log(2)

  if (is.null(log_post_current)) {
    log_post_current <- log_post_dist_gs(gs_current, delta, Phi, r, Sy, n)
  }
  log_post_proposed <- log_post_dist_gs(gs_prop, delta, Phi, r, Sy, n)
  log_post_ratio <- log_post_proposed - log_post_current

  exp(log_post_ratio + log_q_ratio)
}

# =============================================================================
# MH Acceptance Probability — Algorithm 3 (Data-Driven Proposal)
# =============================================================================

comp_prob_algo3 <- function(gs_current, gs_prop, move_type, edge, Sy, n,
                            delta, r, Phi, Kmat,
                            add_current = NULL, del_current = NULL,
                            forward_flipped = FALSE,
                            log_post_current = NULL) {
  i <- edge[1]
  j <- edge[2]
  eps <- 1e-10
  # Only compute the one prop-side set we actually need (see comp_prob note).
  # Boundary detection (forward_flipped / backward_flipped) — see comp_prob
  # for the full justification of why the O(1) edge-count check is complete.
  m_total <- (ncol(gs_prop$G) * (ncol(gs_prop$G) - 1)) / 2
  e_prop <- sum(gs_prop$G[upper.tri(gs_prop$G)])
  if (move_type == "add") {
    w_forward_target <- abs(Kmat[i, j])
    w_forward_sum <- sum(sapply(add_current, function(x) abs(Kmat[x[1], x[2]])))
    log_q_forward <- log(w_forward_target) - log(w_forward_sum)

    del_prop <- get_deletable_edges(gs_prop$G)
    w_backward_target <- 1 / (abs(Kmat[i, j]) + eps)
    w_backward_sum <- sum(sapply(del_prop, function(x) 1 / (abs(Kmat[x[1], x[2]]) + eps)))
    log_q_backward <- log(w_backward_target) - log(w_backward_sum)
    backward_flipped <- (e_prop == m_total)  # G_prop complete ⟹ add_prop empty
  } else {
    w_forward_target <- 1 / (abs(Kmat[i, j]) + eps)
    w_forward_sum <- sum(sapply(del_current, function(x) 1 / (abs(Kmat[x[1], x[2]]) + eps)))
    log_q_forward <- log(w_forward_target) - log(w_forward_sum)

    add_prop <- get_addable_edges(gs_prop$G)
    w_backward_target <- abs(Kmat[i, j])
    w_backward_sum <- sum(sapply(add_prop, function(x) abs(Kmat[x[1], x[2]])))
    log_q_backward <- log(w_backward_target) - log(w_backward_sum)
    backward_flipped <- (e_prop == 0)         # G_prop empty ⟹ del_prop empty
  }

  log_q_ratio <- log_q_backward - log_q_forward
  # Boundary correction (Issue #20, finding F1): same as comp_prob.
  if (forward_flipped)  log_q_ratio <- log_q_ratio - log(2)
  if (backward_flipped) log_q_ratio <- log_q_ratio + log(2)

  if (is.null(log_post_current)) {
    log_post_current <- log_post_dist_gs(gs_current, delta, Phi, r, Sy, n)
  }
  log_post_proposed <- log_post_dist_gs(gs_prop, delta, Phi, r, Sy, n)
  log_post_ratio <- log_post_proposed - log_post_current

  exp(log_post_ratio + log_q_ratio)
}

# =============================================================================
# MH Step: Single Edge Update (graph-state version)
# =============================================================================

mh_edges <- function(gs_current, Sy, n, delta, r, Phi, data_prop = FALSE,
                     Kmat = NULL, log_post_current = NULL) {
  # Caching layer (Issue #25):
  #   - gs_current$add_cache / del_cache: candidate sets, populated lazily
  #     and survive across calls until the graph state is replaced.
  #   - Kmat: caller may supply solve(Sy/n) precomputed once per chain.
  #   - log_post_current: caller may supply log_post_dist_gs(gs_current, ...)
  #     precomputed once per outer SAEM iteration (constant across the M
  #     inner steps until gs_current is replaced).
  # All optional; if NULL, computed locally so the function remains usable
  # by ad-hoc callers outside run_saem_mcmc.
  G_current <- gs_current$G
  move_type <- sample(c("add", "delete"), 1)

  # Only compute the matching-side candidate set. If empty (fully connected or
  # empty graph), flip the move direction and compute the other side.
  # `forward_flipped` is propagated to comp_prob* so the q-ratio gets the
  # correct boundary correction (Issue #20, finding F1).
  add_current <- NULL
  del_current <- NULL
  forward_flipped <- FALSE
  if (move_type == "add") {
    gs_current <- .get_or_compute_add(gs_current)
    add_current <- gs_current$add_cache
    if (length(add_current) == 0) {
      move_type <- "delete"
      gs_current <- .get_or_compute_del(gs_current)
      del_current <- gs_current$del_cache
      candidates <- del_current
      forward_flipped <- TRUE
    } else {
      candidates <- add_current
    }
  } else {
    gs_current <- .get_or_compute_del(gs_current)
    del_current <- gs_current$del_cache
    if (length(del_current) == 0) {
      move_type <- "add"
      gs_current <- .get_or_compute_add(gs_current)
      add_current <- gs_current$add_cache
      candidates <- add_current
      forward_flipped <- TRUE
    } else {
      candidates <- del_current
    }
  }

  if (length(candidates) == 0) return(gs_current)

  # Lazily compute Kmat if data_prop and caller did not supply it.
  if (data_prop && is.null(Kmat)) Kmat <- solve(Sy / n)

  if (data_prop) {
    # Algorithm 3: Data-driven proposal
    if (move_type == "add") {
      weights <- sapply(candidates, function(x) abs(Kmat[x[1], x[2]]))
    } else {
      weights <- sapply(candidates, function(x) 1 / (abs(Kmat[x[1], x[2]]) + 1e-6))
    }
    edge <- candidates[[sample(seq_along(candidates), size = 1, prob = weights)]]
    G_prop <- G_current
    G_prop[edge[1], edge[2]] <- G_prop[edge[2], edge[1]] <- ifelse(move_type == "add", 1, 0)
    gs_prop <- graph_state(G_prop)

    prob_accept <- comp_prob_algo3(gs_current, gs_prop, move_type, edge, Sy, n,
                                   delta, r, Phi, Kmat = Kmat,
                                   add_current = add_current, del_current = del_current,
                                   forward_flipped = forward_flipped,
                                   log_post_current = log_post_current)
  } else {
    # Algorithm 2: Uniform proposal
    edge <- candidates[[sample(seq_along(candidates), 1)]]
    G_prop <- G_current
    G_prop[edge[1], edge[2]] <- G_prop[edge[2], edge[1]] <- ifelse(move_type == "add", 1, 0)
    gs_prop <- graph_state(G_prop)

    prob_accept <- comp_prob(gs_current, gs_prop, move_type, Sy, n,
                             delta, r, Phi,
                             add_current = add_current, del_current = del_current,
                             forward_flipped = forward_flipped,
                             log_post_current = log_post_current)
  }

  if (runif(1) < prob_accept) gs_prop else gs_current
}

# =============================================================================
# SA Step: Sufficient Statistics (graph-state versions)
# =============================================================================

compute_s1_gs <- function(gs) {
  cliques <- gs$cliques
  seps <- gs$separators
  sum_sq_cliq <- sum(sapply(cliques, function(x) length(x)^2))
  sum_sq_seps <- if (length(seps) == 0) 0 else sum(sapply(seps, function(x) length(x)^2))
  sum_sq_cliq - sum_sq_seps
}

compute_s2_gs <- function(gs, Sy, n, delta, Phi) {
  cliques <- gs$cliques
  seps <- gs$separators

  # NOTE: the returned sample is the PRECISION block K_C = Σ_C^{-1} (via the
  # Wishart ↔ Inverse-Wishart duality: rWishart(df, Ψ^{-1}) is a draw of
  # Σ_C^{-1} when Σ_C ~ IW(df, Ψ)). Via Dawid–Lauritzen decomposition of
  # decomposable graphs: tr(Σ_G^{-1}) = Σ_C tr(K_C) - Σ_S tr(K_S).
  #
  # The as.matrix() wrap is required: for |C|=1 or |S|=1, rWishart(...)[,,1]
  # returns a bare scalar, and diag(scalar) in R builds floor(scalar)×floor(scalar)
  # identity instead of the 1×1 matrix's diagonal. The wrap forces matrix semantics.
  traces_C <- sapply(cliques, function(cliq_index) {
    Phi_Sy_C <- as.matrix(Phi[cliq_index, cliq_index] + Sy[cliq_index, cliq_index])
    K_C <- as.matrix(rWishart(1, delta + n, solve(Phi_Sy_C))[, , 1])
    sum(diag(K_C))
  })

  if (length(seps) == 0) {
    traces_S <- 0
  } else {
    traces_S <- sum(sapply(seps, function(sep_index) {
      Phi_Sy_S <- as.matrix(Phi[sep_index, sep_index] + Sy[sep_index, sep_index])
      K_S <- as.matrix(rWishart(1, delta + n, solve(Phi_Sy_S))[, , 1])
      sum(diag(K_S))
    }))
  }

  sum(traces_C) - traces_S
}

compute_s3 <- function(G) {
  sum(G[upper.tri(G)])
}

# Back-compat wrappers (raw matrix)
compute_s1 <- function(G) compute_s1_gs(graph_state(G))
compute_s2 <- function(G, Sy, n, delta, Phi) compute_s2_gs(graph_state(G), Sy, n, delta, Phi)

# =============================================================================
# M-Step: Hyperparameter Updates
# =============================================================================

mstep_tau <- function(delta, G, s1_k, s2_k) {
  p <- ncol(G)
  ((delta - 1) * p + s1_k) / s2_k
}

# NOTE: r_k is floored at 1/(m+1) so that log(r_k) >= -log(m+1). Without the
# floor, (s3_k + 1e-4)/(m + 2e-4) at s3_k = 0 yields r ≈ 2e-6, log(r) ≈ -13,
# which makes any single-edge add move acceptance ≈ e^(-5..-8) at weak signal —
# the empty-graph collapse trap. See Issue #20 (Code Audit) for the
# derivation; documentation in `quality_reports/saem_mcmc_audit_2026-04-28.md`.
#
# Why 1/(m+1) and not the cleaner 1/m: at p = 2, m = 1 and 1/m = 1 would push
# log(1 - r) to -Inf in `log_prior_graph` for any non-saturated graph.
# Using 1/(m+1) keeps r strictly inside (0, 1) for every p >= 2 while
# changing the typical-case floor (p=10: 1/45 vs 1/46) by less than 3%.
mstep_r <- function(s3_k, G) {
  p <- ncol(G)
  m <- (p * (p - 1)) / 2
  r_raw <- (s3_k + 1e-4) / (m + 2e-4)
  max(r_raw, 1 / (m + 1))
}

# =============================================================================
# Warm-start initialiser
# =============================================================================

# Returns a decomposable adjacency matrix derived from the data: the maximum
# spanning tree of the empirical-precision partial-correlation magnitudes.
# A tree is always decomposable, so the result is a valid starting state for
# the decomposable-restricted MH chain. p-1 edges is enough to keep S3_k
# bounded away from 0 during the gamma=1 exploration phase, breaking the
# empty-graph collapse trap (Issue #20).
warmstart_mst <- function(Y, ridge = 1e-3) {
  p <- ncol(Y); n <- nrow(Y)
  Sy <- t(Y) %*% Y
  K_emp <- solve(Sy / n + ridge * diag(p))
  d <- sqrt(pmax(diag(K_emp), 1e-12))
  partial_corr <- abs(-K_emp / outer(d, d))
  diag(partial_corr) <- 0
  # igraph::mst minimises edge weight; we want to KEEP the strongest partial
  # correlations, so feed the inverse magnitude as the "cost". Force exact
  # symmetry — igraph >= 1.6.0 rejects floating-point asymmetry under
  # mode = "undirected".
  cost <- 1 / (partial_corr + 1e-12); diag(cost) <- 0
  cost <- (cost + t(cost)) / 2
  g <- igraph::graph_from_adjacency_matrix(cost, mode = "undirected",
                                           weighted = TRUE, diag = FALSE)
  mst <- igraph::mst(g)
  G <- as.matrix(igraph::as_adjacency_matrix(mst, sparse = FALSE))
  storage.mode(G) <- "integer"
  G
}

# =============================================================================
# Main SAEM-MCMC Algorithm
# =============================================================================

#' Run the SAEM-MCMC algorithm for Bayesian graphical model selection
#'
#' @param Y          Numeric matrix (n x p), the observed data (should be centered/standardized)
#' @param n_iter     Integer, total number of SAEM iterations
#' @param M          Integer, number of MH sub-iterations per SAEM step
#' @param burn_in    Integer, burn-in period (default: 20% of n_iter)
#' @param delta      Numeric, HIW shape parameter (default: 1)
#' @param tau_init   Numeric, initial precision scale (default: 1.1)
#' @param r_init     Numeric, initial edge probability (default: 0.2)
#' @param data_prop  Logical, use Algorithm 3 data-driven proposal (default: FALSE)
#' @param init_graph One of `"mst"` (default), `"empty"`, or a user-supplied
#'                   p x p decomposable adjacency matrix. `"mst"` warm-starts
#'                   the chain at the maximum spanning tree of the empirical
#'                   partial-correlation magnitudes (Issue #20: avoids the
#'                   empty-graph collapse trap). `"empty"` reproduces the
#'                   original Donnet-Marin recipe. A user matrix is checked
#'                   for symmetry, binary entries, zero diagonal, and
#'                   decomposability before use.
#' @param verbose    Integer, print progress every verbose iterations (0 = silent)
#' @return Named list with pip_matrix, G_final, history, G_history, params
run_saem_mcmc <- function(Y, n_iter = 5000, M = 1, burn_in = NULL,
                          delta = 1, tau_init = 1.1, r_init = 0.2,
                          data_prop = FALSE, init_graph = "mst", verbose = 50) {

  n <- nrow(Y)
  p <- ncol(Y)
  Sy <- t(Y) %*% Y
  if (is.null(burn_in)) burn_in <- floor(0.2 * n_iter)
  # Validate burn_in: `burn_in:n_iter` with burn_in > n_iter silently produces
  # a descending sequence, which would corrupt pip_matrix and frac_empty.
  stopifnot(
    "n_iter must be a positive integer" =
      length(n_iter) == 1 && n_iter == as.integer(n_iter) && n_iter > 0,
    "burn_in must be in [0, n_iter - 1]" =
      length(burn_in) == 1 && burn_in == as.integer(burn_in) &&
      burn_in >= 0 && burn_in < n_iter
  )

  # Pre-allocate storage
  history_tau <- numeric(n_iter)
  history_r <- numeric(n_iter)
  log_lik_history <- numeric(n_iter)
  edge_count <- numeric(n_iter)
  G_history <- array(NA, dim = c(p, p, n_iter))

  # Initialize. The default warm-start (MST of empirical partial correlations)
  # avoids the empty-graph collapse trap diagnosed in Issue #20.
  tau_k <- tau_init
  r_k <- r_init
  G_init <- if (is.character(init_graph)) {
    switch(init_graph,
      "mst"   = warmstart_mst(Y),
      "empty" = diag(0L, p),
      stop("Unknown init_graph: ", init_graph,
           " (use \"mst\", \"empty\", or supply a p x p adjacency matrix)"))
  } else if (is.matrix(init_graph)) {
    stopifnot(
      "init_graph must be square" = nrow(init_graph) == ncol(init_graph),
      "init_graph dim must match Y" = nrow(init_graph) == p,
      "init_graph must be symmetric" = isSymmetric(init_graph),
      "init_graph must be 0/1" = all(init_graph %in% c(0L, 1L, 0, 1)),
      "init_graph diagonal must be 0" = all(diag(init_graph) == 0)
    )
    G0 <- init_graph; storage.mode(G0) <- "integer"
    if (!is_decomposable(G0)) stop("init_graph is not decomposable.")
    G0
  } else {
    stop("init_graph must be \"mst\", \"empty\", or a p x p adjacency matrix.")
  }
  gs_current <- graph_state(G_init)
  S1_k <- 0
  S2_k <- 0
  S3_k <- 1  # Do NOT initialize at zero — causes r_k to go out of bounds

  # Caching layer (Issue #25). Bit-identical to the un-cached chain.
  #   - Kmat: solve(Sy/n) is constant across all iterations and only used
  #     under data_prop = TRUE. Compute once outside the loop.
  #   - log_post_current: log_post_dist_gs(gs_current, ...) is constant
  #     across the M inner MH steps within an outer iteration (Phi, r are
  #     constant within an iter and gs_current only changes on accept).
  #     Refresh at the start of each outer iter and on accept; otherwise
  #     reuse.
  #   - gs_current$add_cache, gs_current$del_cache: candidate sets,
  #     populated lazily by mh_edges via .get_or_compute_{add,del}().
  Kmat <- if (data_prop) solve(Sy / n) else NULL

  for (k in 1:n_iter) {
    Phi_k <- tau_k * diag(p)

    # Snapshot of the pre-MH state for history recording (Erik's semantics)
    gs_history <- gs_current

    # log_post_current is constant across the M inner steps for the same
    # gs_current under fixed (Phi_k, r_k); refresh here, refresh again on
    # accept inside the loop.
    log_post_current <- log_post_dist_gs(gs_current, delta, Phi_k, r_k, Sy, n)

    # 1. S-Step: MH updates to graph G (gs_current evolves)
    for (m in 1:M) {
      gs_new <- mh_edges(gs_current, Sy = Sy, n = n, delta = delta,
                         r = r_k, Phi = Phi_k, data_prop = data_prop,
                         Kmat = Kmat, log_post_current = log_post_current)
      # Detect whether the move was accepted by comparing only the
      # adjacency, not the whole graph_state: on rejection mh_edges
      # may return gs_current with newly populated cache fields, so a
      # whole-object `identical()` would falsely flag the rejection
      # as an accept and trigger an unnecessary log_post recomputation.
      graph_changed <- !identical(gs_new$G, gs_current$G)
      gs_current <- gs_new
      if (graph_changed) {
        # Move was accepted; refresh log_post_current for the new graph.
        log_post_current <- log_post_dist_gs(gs_current, delta, Phi_k, r_k, Sy, n)
      }
    }
    gs_post_mh <- gs_current  # Post-MH state used for sufficient statistics

    # 2. SA-Step: Stochastic approximation of sufficient statistics (post-MH graph)
    s1_sample <- compute_s1_gs(gs_post_mh)
    s2_sample <- compute_s2_gs(gs_post_mh, Sy, n, delta, Phi_k)
    s3_sample <- compute_s3(gs_post_mh$G)

    gamma_k <- if (k < 100) 1 else 1 / (k - 99)

    S1_k <- S1_k + gamma_k * (s1_sample - S1_k)
    S2_k <- S2_k + gamma_k * (s2_sample - S2_k)
    S3_k <- S3_k + gamma_k * (s3_sample - S3_k)

    # 3. M-Step: Update hyperparameters (using pre-MH graph, matches Erik's semantics)
    G_hist <- gs_history$G
    tau_k <- mstep_tau(delta, G_hist, S1_k, S2_k)
    r_k <- mstep_r(S3_k, G_hist)

    # Record history (pre-MH state, matches Erik's run_experiment)
    history_tau[k] <- tau_k
    history_r[k] <- r_k
    log_lik_history[k] <- log_hiw_norm_gs(gs_history, delta + n, Phi_k + Sy) -
      log_hiw_norm_gs(gs_history, delta, Phi_k)
    edge_count[k] <- sum(G_hist[upper.tri(G_hist)])
    G_history[, , k] <- G_hist

    if (verbose > 0 && k %% verbose == 0) {
      cat(sprintf("Iteration: %d | tau: %.3f | r: %.3f | loglik: %.3f\n",
                  k, tau_k, r_k, log_lik_history[k]))
    }
  }

  G_final <- gs_current$G

  # Posterior inclusion probabilities from stable samples
  stable_samples <- G_history[, , (burn_in + 1):n_iter]
  pip_matrix <- apply(stable_samples, c(1, 2), mean)

  # Transfer column names if available
  if (!is.null(colnames(Y))) {
    colnames(pip_matrix) <- rownames(pip_matrix) <- colnames(Y)
    colnames(G_final) <- rownames(G_final) <- colnames(Y)
  }

  # Trap diagnostic: fraction of post-burnin iterations spent at the empty
  # graph. > 0.5 indicates the chain hit the empty-graph collapse trap
  # (Issue #20). With the warm-start + r_k floor in place this should be ~0
  # for any reasonable Y; surfacing it lets future regressions be caught.
  frac_empty <- mean(edge_count[(burn_in + 1):n_iter] == 0)

  list(
    pip_matrix = pip_matrix,
    G_final = G_final,
    history = list(
      tau = history_tau,
      r = history_r,
      loglik = log_lik_history,
      edges = edge_count
    ),
    G_history = G_history,
    params = list(tau = tau_k, r = r_k, delta = delta),
    diagnostics = list(frac_empty = frac_empty)
  )
}

# =============================================================================
# Evaluation Metrics
# =============================================================================

calc_metrics <- function(G_est, G_true) {
  est <- as.numeric(G_est[upper.tri(G_est)])
  tru <- as.numeric(G_true[upper.tri(G_true)])

  tp <- sum(est == 1 & tru == 1)
  tn <- sum(est == 0 & tru == 0)
  fp <- sum(est == 1 & tru == 0)
  fn <- sum(est == 0 & tru == 1)

  tpr <- ifelse(tp + fn == 0, 0, tp / (tp + fn))
  fpr <- ifelse(fp + tn == 0, 0, fp / (fp + tn))

  num <- (tp * tn) - (fp * fn)
  den <- sqrt((tp + fp) * (tp + fn) * (tn + fp) * (tn + fn))
  mcc <- if (den == 0) 0 else num / den

  hamming <- fp + fn  # edge disagreements on the upper triangle

  data.frame(TPR = tpr, FPR = fpr, MCC = mcc, Hamming = hamming)
}

# =============================================================================
# Data Generation Helpers (for simulations)
# =============================================================================

#' Generate a true graph adjacency matrix.
#'
#' @param p     Integer, number of vertices (>= 2; >= 4 for "cycle").
#' @param type  One of "chain", "star" (always decomposable), "cycle"
#'              (non-decomposable for p >= 4), "erdos_renyi" (decomposable
#'              only for very sparse realisations), "barabasi_albert"
#'              (decomposable iff a tree, i.e. ba_m = 1). For randomized
#'              topologies (ER, BA) use `set.seed()` upstream for
#'              reproducibility.
#'
#'              **MODEL-CLASS WARNING (Issue #20).** The SAEM-MCMC
#'              inference here restricts moves to decomposable graphs by
#'              construction (HIW prior is only defined on the decomposable
#'              class). For "cycle", "erdos_renyi", and "barabasi_albert"
#'              with ba_m >= 2, the true graph is typically NOT in the
#'              decomposable class, so the algorithm cannot recover it
#'              exactly — only the best decomposable approximation. MCC
#'              against such a truth has a misspecification ceiling < 1.
#'
#' @param er_prob   Edge probability for "erdos_renyi"; defaults to 2/p
#'                  (sparse regime, ~p edges in expectation).
#' @param ba_power  Preferential-attachment exponent for "barabasi_albert"
#'                  (default 1, classical BA).
#' @param ba_m      Edges added per new node for "barabasi_albert"
#'                  (default 1, tree-like; larger gives denser hubs).
#' @return p x p symmetric 0/1 adjacency matrix with zero diagonal.
generate_true_graph <- function(p, type = "chain",
                                er_prob = NULL, ba_power = 1, ba_m = 1) {
  if (!is.numeric(p) || length(p) != 1 || p != as.integer(p) || p < 2) {
    stop("`p` must be an integer >= 2.")
  }
  G <- matrix(0, p, p)
  if (type == "chain") {
    for (i in 1:(p - 1)) G[i, i + 1] <- G[i + 1, i] <- 1
  } else if (type == "star") {
    G[1, 2:p] <- G[2:p, 1] <- 1
  } else if (type == "cycle") {
    if (p < 4) stop("cycle topology requires p >= 4 (smaller cycles are decomposable).")
    for (i in 1:(p - 1)) G[i, i + 1] <- G[i + 1, i] <- 1
    G[1, p] <- G[p, 1] <- 1
  } else if (type == "erdos_renyi") {
    prob <- if (is.null(er_prob)) 2 / p else er_prob
    # An ER draw at sparse `prob` can legitimately be the empty graph
    # (probability `(1-prob)^m`, ~0.6% at p=5/prob=0.4, 1e-5 at p=10/prob=0.2).
    # The downstream simulation drivers `stopifnot(sum(G) > 0)` to catch
    # silent dispatch fall-throughs (Issue #20); a legitimately-empty ER
    # would spuriously trip that guard. Resample up to a small cap before
    # raising. The cap is large enough to make a true empty result
    # astronomically unlikely (cap=50 → P(all empty) <= 1e-250 at p=5).
    G <- matrix(0, p, p)
    for (attempt in seq_len(50)) {
      g <- igraph::sample_gnp(p, prob, directed = FALSE, loops = FALSE)
      G <- as.matrix(igraph::as_adjacency_matrix(g, sparse = FALSE))
      if (sum(G) > 0) break
    }
    if (sum(G) == 0) stop("erdos_renyi sampler returned empty 50 times in a row at p=", p, ", prob=", prob, "; check parameters.")
  } else if (type == "barabasi_albert") {
    # BA at m >= 1 always returns p-1 edges (it's a tree-growing process),
    # so an empty draw is impossible by construction. No retry needed.
    g <- igraph::sample_pa(p, power = ba_power, m = ba_m, directed = FALSE)
    G <- as.matrix(igraph::as_adjacency_matrix(g, sparse = FALSE))
  } else {
    stop("Unknown topology: ", type,
         " (use 'chain', 'star', 'cycle', 'erdos_renyi', or 'barabasi_albert')")
  }
  storage.mode(G) <- "integer"
  G
}

#' Generate Gaussian data with conditional independence structure given by G_true.
#'
#' Constructs a precision matrix \eqn{\Omega} with diagonal `diagonal_strength`
#' and off-diagonal `edge_strength` on edges of `G_true`. If the resulting
#' matrix is not positive-definite (degree heterogeneity, e.g. high-degree
#' BA hubs), the diagonal is shifted by the minimum eigenvalue plus `pd_eps`
#' to recover positive definiteness. Existing decomposable scenarios (chain,
#' star) at the default strengths are PD without adjustment, so they are
#' bit-identical to the pre-extension behavior.
generate_simulation_data <- function(G_true, n, diagonal_strength = 15,
                                     edge_strength = 1.9, pd_eps = 0.1) {
  p <- ncol(G_true)
  Omega_true <- diag(diagonal_strength, p)
  Omega_true[G_true == 1] <- edge_strength

  min_eig <- min(eigen(Omega_true, symmetric = TRUE, only.values = TRUE)$values)
  if (min_eig < pd_eps) {
    Omega_true <- Omega_true + (pd_eps - min_eig) * diag(p)
  }

  Sigma_true <- solve(Omega_true)
  Y <- MASS::mvrnorm(n, mu = rep(0, p), Sigma = Sigma_true)
  list(Y = Y, Omega_true = Omega_true, Sigma_true = Sigma_true)
}
