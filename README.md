# README

This workspace contains **two self-contained code samples**: one in **Python** and one in **Stata**. They address different parts of an empirical pipeline and can be run independently.

---

## 1) Python sample — Pair-Year Event Summaries by Group & Interlock Scenario

**Goal.** Build **pair-year–level** summaries for each **disease/therapeutic** group under three interlock scenarios—**Indirect**, **Direct**, and **No Interlock**—then export wide “master” tables, legacy per-scenario tables, year-of-onset (YoY) tables, and YoY-by-history tables.

### What it computes

* **Counts**: number of BoardName1–BoardName2 pairs that satisfy each mask (A.1–A.10, B.1–B.10, RN1–RN5) within each scenario.
* **Shares**: pooled proportions within a scenario, i.e., `mask_count / total_event_count`.
* **YoY bases**: “first year of onset” flags for Indirect/Direct (and “never” for No Interlock).
* **History split**: `no_prior_direct` vs `prior_direct` at t−1 using `cum_interlock_direct_prev`.

### Inputs (read from `InterimData`)

1. **`citeline_originator_firmyr.csv`**
   Firm-year cumulative origination/launch counts for each group:
   `cum_{entity}_n_added_{Group}`, `cum_{entity}_n_launch_{Group}`, where `{entity} ∈ {disease, therapeutic}`.

2. **`cro_bname_boardex_citeline.dta`**
   Cross-walk / whitelist of valid `BoardName` values (used to filter firms and pairs).

3. **`boardex_citeline_originator_sample.csv`**
   Pair-year interlock indicators: `interlock_indirect`, `interlock_direct`.
   Used to construct Indirect/Direct/No Interlock scenario masks and YoY/history flags.

### Outputs (written to `tables/3_stats/citeline_originate`)

**Master (wide) tables**

* `full_disease_results_with_all_scenarios.csv`
* `full_therapeutic_results_with_all_scenarios.csv`
  Each contains per-scenario totals plus A.1–A.10, B.1–B.10, RN1–RN5 counts and shares.

**Legacy per-scenario tables** (therapeutic versions are prefixed with `therapeutic_`)

* `originate_changes_interlock_indirect_with_shares.csv`
* `originate_changes_interlock_direct_with_shares.csv`
* `originate_changes_not_interlock_indirect_with_shares.csv`

**Year-of-Onset (YoY)**

* `originate_changes_interlock_indirect_with_shares_YoY_events.csv`
* `originate_changes_interlock_direct_with_shares_YoY_events.csv`
* `originate_changes_not_interlock_with_shares_YoY_events.csv`

**YoY by prior-direct history**

* `originate_changes_interlock_indirect_with_shares_by_prior_direct_history.csv`
* `originate_changes_interlock_direct_with_share_by_prior_direct_history.csv`

> **Note:** For therapeutic outputs, the same filenames are emitted with the `therapeutic_` prefix.

### How to run

* Ensure the three input files exist under your `InterimData` folder.
* Adjust the hard-coded paths in the script if needed (Windows/macOS branches are included).
* Run from a terminal:

  ```bash
  python <your_python_script>.py
  ```
* The script writes all CSV outputs to the target `tables/3_stats/citeline_originate` directory.

### Python environment

* Python ≥ 3.9
* Packages: `pandas`, `numpy`, `psutil` (optional, for RAM logging)

---

## 2) Stata sample — Dual-Variant DID/ES Analysis (WITH/without trend)

**Goal.** Estimate treatment effects on multiple outcomes with and without a linear treatment trend, plus heterogeneity, robustness, placebo, CSDID, Bacon decomposition, and event-study diagnostics.

### What it does

* **Data prep**: panel setup (`xtset`), treatment timing (`treated`, `post`, `treated_post`, `rel_time`), winsorizing, logs, flexible time interactions, and city-level covariates.
* **Two variants**:

  * **Variant A (WITH `treatment_trend`)**
  * **Variant B (WITHOUT `treatment_trend`)**
* **Outcomes**:

  * Core: `lnStaffSalaryLevel`, `lnStaffNumber`
  * “Structural” measures: `jishu`, `shengchan`, `lowla`
  * Recruitment activity (counts/logs)
  * Subsidies (total, tech, labor)
  * Patents (`total_patents`, `valid_patents`, logs)
  * Job-posting wages and rates (2016+ subset)
  * Productivity (TFP variants, `perTFP`, `perY`)
  * AI investment (software/hardware/total levels)
* **Heterogeneity**: interactions with `ISAI`, `ISsz`, and industry group dummies (`labor_intensive`, `tech_intensive`, `capital_intensive`).
* **Event studies**: `eventdd` with and without `treatment_trend`, city FE robustness, and alternative time windows.
* **Placebo**: permutation tests (saves `sim_*.dta`).
* **CSDID**: optional runs if `city_id` exists, with `estat event` storage.
* **Bacon decomposition**: timing diagnostics via `ddtiming`.

### Inputs & paths

* Expects a Stata dataset named **`reg_mechan_final`** in the working directory.
* Set the working path at the top of the script:

  ```stata
  global path "D:\RA\公司\"
  cd "$path"
  use reg_mechan_final, clear
  ```
* The script handles string-to-numeric conversions for keys and constructs all required controls.

### Outputs / artifacts

* **Permutation (placebo) results** saved as:

  * `sim_lnStaffSalaryLevel_trend1.dta`, `sim_lnStaffNumber_trend1.dta` (with trend)
  * `sim_lnStaffSalaryLevel_trend0.dta`, `sim_lnStaffNumber_trend0.dta` (without trend)
* **Event-study results** are graphed (via `eventdd` options) and stored for inspection; CSDID event paths are `estore`’d (named objects) inside Stata.
* Regressions use `cluster(city)` and absorb fixed effects as specified.

### Stata requirements

Install these packages (SSC):

```stata
ssc install reghdfe, replace
ssc install winsor2, replace
ssc install eventdd, replace
ssc install csdid, replace
ssc install ddtiming, replace
```

---

## Suggested folder layout

```
/InterimData
  ├─ citeline_originator_firmyr.csv
  ├─ cro_bname_boardex_citeline.dta
  ├─ boardex_citeline_originator_sample.csv
/tables/3_stats/citeline_originate
/code
  ├─ <python_script>.py
  └─ <stata_script>.do
```

---

## Reproducibility notes

* The Python sample assumes specific input column names (listed above). If your data headers differ, update the script accordingly.
* The Stata sample includes robust checks (alternative windows, city FE) and placebo permutations with fixed seeds for replicability.
* Both samples log or store intermediate artifacts (e.g., RAM in Python; `estat` stored results in Stata) to help audit each step.

---

## Contact / Issues

If you adapt the scripts to new data sources or change naming conventions (columns, paths), search for the path and column constants near the top of each file and update them in one place.
