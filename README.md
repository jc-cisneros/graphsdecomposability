# Diagnosing Robustness of Decomposability in Gaussian Graphical Models

Reproducible code, data, and writeup for the paper *Diagnosing Robustness of
Decomposability in Gaussian Graphical Models* by Juan Carlos Cisneros and
Erik Solé (Universitat Pompeu Fabra, 2026).

The paper assesses the empirical-Bayes SAEM-MCMC procedure of
[Donnet and Marin (2012)](https://doi.org/10.1080/10618600.2012.687388) for
decomposable Gaussian graphical models and characterizes the regimes in which
its central decomposability assumption is, and is not, costly. We propose
using the two-stage output (Stage 1 decomposable + Stage 2 unrestricted via
[BDgraph](https://cran.r-project.org/package=BDgraph)) as a diagnostic for
misspecification of the decomposable family, and apply the procedure to the
[Demirer-Diebold-Liu-Yilmaz (2018)](https://doi.org/10.1002/jae.2585)
global bank-volatility panel ($n = 2{,}676$, $p = 106$).

## Repository layout

```
1_data/        DDLY raw CSV + bank-name lookup; wrangling script
2_analysis/    Three R scripts: simulation grid, DDLY application, lambda-sensitivity sweep
3_slides/      Beamer source for the conference deck
4_paper/       LaTeX source for the paper, plus bibliography and section files
utils/         R helpers actually sourced by the analysis (SAEM-MCMC, two-stage wrapper, comparators)
lib/           Shell helpers used by the per-module make.sh scripts
```

## Reproducing the paper and slides

The build is orchestrated by per-module `make.sh` scripts and a top-level
`run_all.sh`. The R environment is pinned via
[micromamba](https://mamba.readthedocs.io/en/latest/user_guide/micromamba.html)
and `conda-lock.yml`; LaTeX uses [tectonic](https://tectonic-typesetting.github.io/)
plus [biber](https://biblatex-biber.sourceforge.net/) for the bibliography.

### One-time setup

```bash
bash setup.sh         # installs micromamba, R, tectonic into .micromamba/
bash setup_biber.sh   # installs biber binary (tectonic does not ship it)
```

### Full rebuild

```bash
bash run_all.sh
```

This runs, in order:

1. `1_data/make.sh` — wrangle the raw DDLY CSV into `1_data/output/ddly_clean.rds`
2. `2_analysis/make.sh` — run the simulation grid, DDLY application, and lambda-sensitivity sweep; write figures and LaTeX tables under `2_analysis/output/`
3. `3_slides/make.sh` — compile the slides → `3_slides/output/slides.pdf`
4. `4_paper/make.sh` — compile the paper → `4_paper/output/paper.pdf`

### Compile only the writeup

If you just want the PDFs and trust the precomputed analysis outputs that ship
with the repo (`2_analysis/output/figures/` and `2_analysis/output/tables/`):

```bash
bash 3_slides/make.sh    # → 3_slides/output/slides.pdf
bash 4_paper/make.sh     # → 4_paper/output/paper.pdf
```

### Runtime budget

The simulation grid in `2_analysis/source/run_simulations_extended.r` is the
expensive step (~30 minutes on 8 cores). The DDLY application
(`run_ddly_application.r`) is ~25 minutes for the full $p = 106$ panel.
The lambda-sensitivity sweep is ~10 minutes. The LaTeX build is under a
minute end-to-end.

## Data

- **DDLY bank-volatility panel** — `1_data/source/raw/ddly/ddly-data.csv`:
  ninety-six bank stocks plus ten ten-year sovereign bond series, daily log
  range volatilities from 12 September 2003 to 7 February 2014 ($n = 2{,}676$,
  $p = 106$). Distributed alongside Demirer, Diebold, Liu, and Yilmaz (2018);
  the cleaned long-format `ddly_clean.rds` is rebuilt by `1_data/make.sh`.
- **Bank-name lookup** — `1_data/source/raw/ddly/bank_names.csv`: ticker →
  bank name mapping parsed from the DDLY data appendix.

## Citation

If you use this code or build on the diagnostic, please cite the paper:

```bibtex
@unpublished{cisneros_sole_2026_diagnosing,
  title  = {Diagnosing Robustness of Decomposability in Gaussian Graphical Models},
  author = {Cisneros, Juan Carlos and Sol{\'e}, Erik},
  year   = {2026},
  note   = {Universitat Pompeu Fabra}
}
```

## License

MIT — see [`LICENSE`](LICENSE).

## Contact

Juan Carlos Cisneros — juancarlos.cisneros@upf.edu
