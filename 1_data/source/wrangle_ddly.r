# =============================================================================
# DDLY (2018) bank-volatility data wrangling
#
# Source: 1_data/source/raw/ddly/ddly-data.csv
#   - 2676 daily observations, 2003-09-12 to 2014-02-07
#   - 96 bank stock daily-range volatilities (columns ordered by total assets,
#     descending; first row of header carries Reuters tickers)
#   - 10 sovereign 10-year government bond volatilities (last 10 columns)
#
# Output: 1_data/output/ddly_clean.rds
#   - $Y          : 2676 x 106 matrix of log-volatilities (rows = days)
#   - $dates      : Date vector of length 2676
#   - $metadata   : tibble mapping column_idx, ticker, country, region, asset_class
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tibble)
})

set.seed(20260427)

# ---- Read raw CSV ----------------------------------------------------------
raw <- read.table("raw/ddly/ddly-data.csv",
                  sep = ";", header = TRUE,
                  na.strings = c("", "NA"),
                  stringsAsFactors = FALSE,
                  check.names = FALSE)

stopifnot(nrow(raw) == 2676, ncol(raw) == 107)

# Parse dates (dd/mm/yy format; 2-digit years all fall in 2003-2014).
dates <- as.Date(raw[[1]], format = "%d/%m/%y")
stopifnot(all(!is.na(dates)))

# Drop the date column from the matrix.
Y_raw <- as.matrix(raw[, -1, drop = FALSE])
storage.mode(Y_raw) <- "double"

# ---- Sanity checks ---------------------------------------------------------
stopifnot(
  ncol(Y_raw) == 106L,
  all(!is.na(Y_raw)),
  all(Y_raw > 0)        # range volatilities are strictly positive
)

# ---- Log transform ---------------------------------------------------------
# Daily range volatilities span 1e-6 to 1e-2, heavily right-skewed in the
# original scale. log(.) yields roughly Gaussian marginals (Garman-Klass-style
# log-volatility), which is the appropriate input for a Gaussian graphical
# model. We do NOT standardize because the GGM is invariant to per-variable
# scale: zeros of the precision matrix and partial-correlation magnitudes
# are unchanged by per-column rescaling, so standardization is unnecessary
# (though it may help numerically in other workflows).
Y <- log(Y_raw)

# ---- Metadata: ticker -> country -> region --------------------------------
# Country mapping is built from Reuters-ticker suffixes (the right-of-dot
# code unambiguously identifies the listing exchange) plus a hand-coded
# override table for the cases where the suffix is shared across countries
# (e.g. ".to" = Toronto, used by both Canadian banks and Japanese banks
# listed as TYO ADRs in the data; ".kr" / ".kn" / ".se" require manual
# assignment because the appendix uses non-standard codes).
#
# Source for the override table: pp.\ 1-4 of the DDLY (2018) Online Appendix
# (see 1_data/source/raw/ddly/data-appendix.pdf, Table A1).

tickers <- colnames(Y)
n_series <- length(tickers)

# Sovereign bonds: by construction the last 10 columns.
is_bond <- grepl("_b$", tickers)
stopifnot(sum(is_bond) == 10L)

bond_country <- c(US_b = "US",  UK_b  = "UK",  GER_b = "Germany",
                  FRA_b = "France", ITA_b = "Italy", ESP_b = "Spain",
                  GRC_b = "Greece", JPN_b = "Japan", CAN_b = "Canada",
                  AUS_b = "Australia")

# Bank country mapping. Tickers appear in ddly-data.csv exactly as listed
# below. Unmapped tickers are flagged at the end.
bank_country <- c(
  hsba.ln  = "UK",       x8306.to = "Japan",   bnp.fr   = "France",
  jpm      = "US",       dbk.xe   = "Germany", barc.ln  = "UK",
  aca.fr   = "France",   bac      = "US",      c        = "US",
  x8411.to = "Japan",    gle.fr   = "France",  rbs.ln   = "UK",
  x8316.to = "Japan",    san.mc   = "Spain",   wfc      = "US",
  inga.ae  = "Netherlands", lloy.ln = "UK",    ucg.mi   = "Italy",
  ubsn.vx  = "Switzerland", csgn.vx = "Switzerland",
  gs       = "US",       ndasek.sk = "Sweden", isp.mi  = "Italy",
  ms       = "US",       td.t     = "Canada",  ry.t    = "Canada",
  bbva.mc  = "Spain",    cbk.xe   = "Germany", nab.au  = "Australia",
  bns.t    = "Canada",   cba.au   = "Australia", stan.ln = "UK",
  x600036.sh = "China",  anz.au   = "Australia", wbc.au = "Australia",
  x600000.sh = "China",  danske.ko = "Denmark", sber.mz = "Russia",
  x600016.sh = "China",  bmo.t    = "Canada",   itub4.br = "Brazil",
  x8308.to = "Japan",    x8604.to = "Japan",    x8309.to = "Japan",
  sbin.in  = "India",    dnb.os   = "Norway",   shba.sk = "Sweden",
  seba.sk  = "Sweden",   cm.t     = "Canada",   bk.us   = "US",
  usb      = "US",       bbdc4.br = "Brazil",   kbc.bt  = "Belgium",
  pnc.us   = "US",       d05.sg   = "Singapore", x000001.sz = "China",
  x053000.se = "Korea",  dexb.bt  = "Belgium",  cof     = "US",
  x055550.se = "Korea",  sweda.sk = "Sweden",   x600015.sh = "China",
  ebs.vi   = "Austria",  bmps.mi  = "Italy",    stt.us  = "US",
  sab.mc   = "Spain",    u11.sg   = "Singapore", pop.mc = "Spain",
  x024110.se = "Korea",  bbt      = "US",       bir.db = "Ireland",
  na.t     = "Canada",   sti.us   = "US",       bp.mi  = "Italy",
  maybank.ku = "Malaysia", aib.db = "Ireland",  sbk.jo = "South Africa",
  axp      = "US",       ete.at   = "Greece",   nbg.at = "Greece",
  bbas3.br = "Brazil",
  # Filled from the back of the assets-sorted list (DDLY appendix Table A1
  # continued; remaining entries identified via Reuters Eikon).
  mqg.au     = "Australia", x8354.to = "Japan",  x8332.to = "Japan",
  poh1s.he   = "Finland",   fitb.us  = "US",     rf.us    = "US",
  uni.mi     = "Italy",     bcp.lb   = "Portugal", cimb.ku = "Malaysia",
  bankbaroda.in = "India",  isctr.is = "Turkey", bes.lb   = "Portugal",
  x8377.to   = "Japan",     x8355.to = "Japan",
  x8331.to   = "Japan",     x8418.to = "Japan",  mb.mi = "Italy"
)

# ---- Verify completeness of the ticker -> country map ---------------------
# Lookups are case-insensitive: DDLY's CSV mixes case across rows
# (e.g. ndasek.sk but X053000.SE; bbt vs BBT), so we lowercase both sides.
mapped <- c(bond_country, bank_country)
names(mapped) <- tolower(names(mapped))
country_vec <- unname(mapped[tolower(tickers)])
unmatched <- tickers[is.na(country_vec)]
if (length(unmatched) > 0) {
  warning("Tickers without country mapping (will be tagged 'Unknown'): ",
          paste(unmatched, collapse = ", "))
}
country_vec[is.na(country_vec)] <- "Unknown"

# ---- Region grouping ------------------------------------------------------
country_to_region <- function(country) {
  case_when(
    country == "US"                                          ~ "US",
    country == "Canada"                                      ~ "Canada",
    country %in% c("UK")                                     ~ "UK",
    country %in% c("France", "Germany", "Italy", "Spain",
                   "Netherlands", "Belgium", "Austria",
                   "Ireland", "Greece", "Finland", "Portugal") ~ "Eurozone",
    country %in% c("Switzerland", "Sweden", "Norway",
                   "Denmark")                                ~ "Other Europe",
    country %in% c("Japan", "China", "Hong Kong", "Korea",
                   "Singapore", "India", "Malaysia",
                   "Indonesia")                              ~ "Asia",
    country %in% c("Australia")                              ~ "Pacific",
    country %in% c("Brazil")                                 ~ "Latin America",
    country %in% c("Russia", "South Africa", "Turkey")       ~ "Other EM",
    TRUE                                                     ~ "Unknown"
  )
}

region_vec <- country_to_region(country_vec)

# ---- Bank names from DDLY appendix Table A1 -------------------------------
# Source: 1_data/source/raw/ddly/data-appendix.pdf, parsed into bank_names.csv
# (96 rows: ticker -> bank_name -> country). Bonds are not in the table; we
# build their display names from the bond_country mapping.
name_lookup <- read.csv("raw/ddly/bank_names.csv", stringsAsFactors = FALSE)

# Case-insensitive merge on ticker to absorb the case mismatches between the
# appendix (lowercase) and the CSV's column headers (mixed case after R's
# check.names mangling).
match_idx <- match(tolower(tickers), tolower(name_lookup$ticker))
bank_name_vec <- name_lookup$bank_name[match_idx]

# Bonds: synthesize a display name from country.
bond_display <- paste0(country_vec, " 10y")
bank_name_vec[is_bond] <- bond_display[is_bond]
stopifnot(all(!is.na(bank_name_vec)))

# Short label for plot use: first 2 words by default, with hand-curated
# overrides for institutions whose first-2-words form is ambiguous (multiple
# "Bank of ..." entities), too long, or culturally awkward (e.g. "Türkiye"
# vs. "Turkiye Is" mid-word truncation). Keys are full bank names from the
# DDLY appendix; values are the labels used on the network plot.
abbrev_map <- c(
  "Royal Bank of Scotland Group"        = "RBS",
  "Royal Bank of Canada"                = "RBC",
  "Industrial Bank of Korea"            = "Industrial Bank (Korea)",
  "Standard Bank Group"                 = "Standard Bank",
  "Turkiye Is Bankasi"                  = "Türkiye Is",
  "Bank of New York Mellon"             = "BNY Mellon",
  "Toronto-Dominion Bank"               = "TD Bank",
  "Bank of Nova Scotia"                 = "Scotiabank",
  "Bank of America"                     = "Bank of America",
  "Bank of Ireland"                     = "Bank of Ireland",
  "Bank of Montreal"                    = "Bank of Montreal",
  "Bank of Baroda"                      = "Bank of Baroda",
  "Bank of Yokohama"                    = "Bank of Yokohama",
  "Bank Of Yokohama"                    = "Bank of Yokohama",
  "JPMorgan Chase & Co"                 = "JPMorgan",
  "Mitsubishi UFJ Financial Group"      = "Mitsubishi UFJ",
  "Sumitomo Mitsui Financial Group"     = "Sumitomo Mitsui",
  "Sumitomo Mitsui Trust Holdings"      = "Sumitomo Mitsui Trust",
  "Goldman Sachs Group"                 = "Goldman Sachs",
  "Banco Bilbao Vizcaya Argentaria"     = "BBVA",
  "Banco Santander"                     = "Santander",
  "Credit Suisse Group"                 = "Credit Suisse",
  "American Express"                    = "Amex",
  "Mediobanca Banca di Credito Finanziario" = "Mediobanca"
)
short_name_vec <- vapply(bank_name_vec, function(nm) {
  if (nm %in% names(abbrev_map)) return(unname(abbrev_map[nm]))
  parts <- strsplit(nm, "\\s+")[[1]]
  paste(head(parts, 2L), collapse = " ")
}, character(1))

# ---- Assemble metadata ----------------------------------------------------
metadata <- tibble(
  column_idx  = seq_len(n_series),
  ticker      = tickers,
  bank_name   = bank_name_vec,
  short_name  = short_name_vec,
  country     = country_vec,
  region      = region_vec,
  asset_class = ifelse(is_bond, "Sovereign bond", "Bank stock")
)

cat("\n=== DDLY data wrangling summary ===\n")
cat(sprintf("Observations: %d days from %s to %s\n",
            nrow(Y), format(dates[1]), format(dates[length(dates)])))
cat(sprintf("Series: %d (%d bank stocks + %d sovereign bonds)\n",
            ncol(Y), sum(!is_bond), sum(is_bond)))

cat("\nBy region:\n")
print(metadata %>%
        group_by(region, asset_class) %>%
        summarise(n = dplyr::n(), .groups = "drop") %>%
        arrange(asset_class, desc(n)))

# ---- Persist --------------------------------------------------------------
out_dir <- "../output"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
out_path <- file.path(out_dir, "ddly_clean.rds")
saveRDS(list(Y = Y, dates = dates, metadata = metadata), out_path)
cat(sprintf("\n[write] %s  (%.1f KB)\n", out_path, file.size(out_path) / 1024))
