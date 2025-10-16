# -*- coding: utf-8 -*-
"""
Purpose
-------
Build pair-year–level event summaries for each disease/therapeutic group across
three interlock scenarios — Indirect, Direct, and No Interlock — and export:

1) Wide "master" tables (per entity: disease / therapeutic) containing:
   - Total event counts by scenario
   - A.1–A.10 & B.1–B.10 mask counts and shares
   - RN1–RN5 counts and shares
2) "Legacy-style" per-scenario CSVs with counts/shares (to match downstream code)
3) YoY (year-of-onset) files for Indirect, Direct, and No Interlock
4) YoY-by-history files for Indirect/Direct, split by prior direct interlock history
   (no_prior_direct / prior_direct at t−1)

Computation highlights
----------------------
- Counts are the number of BoardName1–BoardName2 pairs meeting each mask within a scenario.
- Shares are pooled proportions: mask_count / total_event_count for that scenario.
- YoY bases use the first year of onset (mask_indirect_yoy / mask_direct_yoy) and "never" for No Interlock.
- History split is defined by cum_interlock_direct_prev at t−1 (no_prior_direct vs prior_direct).
- Processing is batched over groups for memory efficiency; lags/leads up to t+3 and LAST are precomputed.

Inputs (read from InterimData)
------------------------------
1) citeline_originator_firmyr.csv
   - Firm-year cumulative origination/launch counts per group:
     cum_{entity}_n_added_{Group}, cum_{entity}_n_launch_{Group}
     where {entity} ∈ {disease, therapeutic}
2) cro_bname_boardex_citeline.dta
   - Crosswalk / whitelist of valid BoardName values (used to filter pairs/firms)
3) boardex_citeline_originator_sample.csv
   - Pair-year interlock indicators:
     interlock_indirect, interlock_direct
   - Used to build scenario masks (Indirect/Direct/No Interlock) and YoY/history flags

Outputs (written to tables/3_stats/citeline_originate)
------------------------------------------------------
Master (wide) tables:
- full_disease_results_with_all_scenarios.csv
- full_therapeutic_results_with_all_scenarios.csv

Legacy per-scenario files (therapeutic versions are prefixed with "therapeutic_"):
- originate_changes_interlock_indirect_with_shares.csv
- originate_changes_interlock_direct_with_shares.csv
- originate_changes_not_interlock_indirect_with_shares.csv

YoY (year-of-onset) files:
- originate_changes_interlock_indirect_with_shares_YoY_events.csv
- originate_changes_interlock_direct_with_shares_YoY_events.csv
- originate_changes_not_interlock_with_shares_YoY_events.csv

YoY by prior-direct history:
- originate_changes_interlock_indirect_with_shares_by_prior_direct_history.csv
- originate_changes_interlock_direct_with_share_by_prior_direct_history.csv

Notes
-----
- For therapeutic outputs, the same filenames are emitted with the "therapeutic_" prefix,
  e.g., therapeutic_originate_changes_interlock_indirect_with_shares.csv.
- "Total_*_Event_Share" in YoY files is 1.0 when the corresponding event count is > 0.
"""

import os, re, gc
import numpy as np
import pandas as pd
import psutil
from typing import List, Dict, Tuple

# ---------------------- Utils ----------------------
def ram_mb() -> float:
    try:
        return psutil.Process().memory_info().rss / 1024**2
    except Exception:
        return float("nan")

def get_paths():
    username = os.environ.get('USER') or os.environ.get('USERNAME')
    if username == 'XXX':
        interim_dir = r"/Users/XXX/Dropbox/BoardPharma/InterimData/"
        output_dir  = r"/Users/XXX/Dropbox/BoardPharma/tables/3_stats/citeline_originate/"
    else:
        interim_dir = r"C:\Users\12150\Dropbox\BoardPharma\InterimData"
        output_dir  = r"C:\Users\12150\Dropbox\BoardPharma\tables\3_stats\citeline_originate"
    os.makedirs(output_dir, exist_ok=True)
    return {'interim': interim_dir, 'output': output_dir}

def detect_groups(columns: List[str], entity: str) -> List[str]:
    pat = re.compile(rf'^cum_{entity}_n_added_(.+)$')
    return [m.group(1) for c in columns for m in [pat.match(c)] if m]

def _first_increment_index_np(v: np.ndarray) -> float:
    """Index of first strictly positive increment relative to the first element after making sequence monotone."""
    if v.size == 0:
        return np.nan
    d = np.diff(v, prepend=v[0])
    # If first is NaN, treat as 0 delta at t0
    if np.isnan(d[0]):
        d[0] = 0.0
    idx = np.flatnonzero(d > 0)
    return float(idx[0]) if idx.size else np.nan

def _compute_causal_flags_for_pairs(
    groups_index,  # dict: (pair) -> row indices
    o1: np.ndarray, l1: np.ndarray,
    o2: np.ndarray, l2: np.ndarray
) -> Tuple[np.ndarray, np.ndarray]:
    """
    For each pair's trajectory, mark if the first LAUNCH increment occurs
    at or after the first ORIGINATE increment (per side).
    Uses monotone (cummax) arrays built in-place without extra groupby.
    """
    n = o1.shape[0]
    ok1 = np.zeros(n, dtype=bool)
    ok2 = np.zeros(n, dtype=bool)
    for _, idx in groups_index.items():
        idx = np.asarray(idx, dtype=np.int64)

        # Robust monotone sequences (ffill-like then cummax)
        o1_seq = np.nan_to_num(o1[idx], nan=0.0)
        l1_seq = np.nan_to_num(l1[idx], nan=0.0)
        o2_seq = np.nan_to_num(o2[idx], nan=0.0)
        l2_seq = np.nan_to_num(l2[idx], nan=0.0)

        o1_m = np.maximum.accumulate(o1_seq)
        l1_m = np.maximum.accumulate(l1_seq)
        o2_m = np.maximum.accumulate(o2_seq)
        l2_m = np.maximum.accumulate(l2_seq)

        o1_i = _first_increment_index_np(o1_m); l1_i = _first_increment_index_np(l1_m)
        o2_i = _first_increment_index_np(o2_m); l2_i = _first_increment_index_np(l2_m)

        if (not np.isnan(o1_i)) and (not np.isnan(l1_i)) and (l1_i >= o1_i): ok1[idx] = True
        if (not np.isnan(o2_i)) and (not np.isnan(l2_i)) and (l2_i >= o2_i): ok2[idx] = True
    return ok1, ok2

# ---------------------- Base (single merge for both entities) ----------------------
def build_base(paths, want_entities=('disease','therapeutic')) -> Tuple[pd.DataFrame, Dict[str, List[str]]]:
    print(f"[base] loading… (RAM {ram_mb():.1f} MB)")
    citeline_path  = os.path.join(paths['interim'], "citeline_originator_firmyr.csv")
    interlock_path = os.path.join(paths['interim'], "boardex_citeline_originator_sample.csv")
    cro_path       = os.path.join(paths['interim'], "cro_bname_boardex_citeline.dta")

    cro = pd.read_stata(cro_path)
    valid = cro['BoardName'].drop_duplicates().astype('string')
    del cro; gc.collect()

    cols0 = pd.read_csv(citeline_path, nrows=0).columns.tolist()
    groups_by_entity: Dict[str, List[str]] = {}
    for ent in want_entities:
        groups_by_entity[ent] = [m for m in
                                 [re.match(rf'^cum_{ent}_n_added_(.+)$', c) for c in cols0]
                                 if m]
        groups_by_entity[ent] = [m.group(1) for m in groups_by_entity[ent]]

    if not any(groups_by_entity.values()):
        raise RuntimeError("No groups found for disease/therapeutic in citeline columns.")

    interlock = pd.read_csv(
        interlock_path,
        usecols=['BoardName1','BoardName2','year','interlock_indirect','interlock_direct'],
        dtype={'BoardName1':'category','BoardName2':'category','year':'int16',
               'interlock_indirect':'float32','interlock_direct':'float32'}
    )
    interlock = interlock[
        interlock['BoardName1'].astype('string').isin(valid) &
        interlock['BoardName2'].astype('string').isin(valid)
    ].copy()

    df = interlock.sort_values(['BoardName1','BoardName2','year'], kind='mergesort')
    for c in ['interlock_indirect','interlock_direct']:
        df[c] = df[c].fillna(0).astype('int8')

    gbp = df.groupby(['BoardName1','BoardName2'], sort=False, observed=True)
    df['L1_interlock_indirect']  = gbp['interlock_indirect'].shift(1).fillna(0).astype('int8')
    df['L1_interlock_direct']    = gbp['interlock_direct'].shift(1).fillna(0).astype('int8')
    df['cum_interlock_indirect'] = gbp['interlock_indirect'].cumsum()
    df['cum_interlock_direct']   = gbp['interlock_direct'].cumsum()

    df['mask_indirect_yoy'] = (df['interlock_indirect'].eq(1) & df['L1_interlock_indirect'].eq(0))
    df['mask_direct_yoy']   = (df['interlock_direct'].eq(1)   & df['L1_interlock_direct'].eq(0))
    df['mask_never']        = (df['cum_interlock_indirect'].eq(0) & df['cum_interlock_direct'].eq(0))
    df['mask_indirect']     = df['mask_indirect_yoy']
    df['mask_direct']       = df['mask_direct_yoy']
    df['mask_no_interlock'] = df['mask_never']

    # history: prior direct cum (t-1)
    df['cum_interlock_direct_prev'] = gbp['cum_interlock_direct'].shift(1).fillna(0).astype('int32')

    print(f"[base] rows={len(df):,}, pairs={gbp.ngroups:,} (RAM {ram_mb():.1f} MB)")
    return df, groups_by_entity

# ---------------------- Attach a batch of entity columns ----------------------
def _attach_entity_batch(base: pd.DataFrame, paths, entity: str, groups: List[str]) -> pd.DataFrame:
    if not groups:
        return None

    citeline_path = os.path.join(paths['interim'], "citeline_originator_firmyr.csv")
    cro_path      = os.path.join(paths['interim'], "cro_bname_boardex_citeline.dta")

    cro = pd.read_stata(cro_path)[['BoardName']].dropna()
    valid = set(cro['BoardName'].astype(str).unique())
    del cro; gc.collect()

    usecols = ['BoardName','year']
    for g in groups:
        usecols += [f'cum_{entity}_n_added_{g}', f'cum_{entity}_n_launch_{g}']

    firm = pd.read_csv(citeline_path, usecols=usecols,
                       dtype={'BoardName':'category','year':'int16'})
    firm = firm[firm['BoardName'].astype(str).isin(valid)].copy()

    ren1 = {'BoardName':'BoardName1','year':'year'}
    ren2 = {'BoardName':'BoardName2','year':'year'}
    for g in groups:
        ren1[f'cum_{entity}_n_added_{g}']  = f'cum_{entity}_n_added_{g}_1'
        ren1[f'cum_{entity}_n_launch_{g}'] = f'cum_{entity}_n_launch_{g}_1'
        ren2[f'cum_{entity}_n_added_{g}']  = f'cum_{entity}_n_added_{g}_2'
        ren2[f'cum_{entity}_n_launch_{g}'] = f'cum_{entity}_n_launch_{g}_2'

    firm1 = firm.rename(columns=ren1)
    firm2 = firm.rename(columns=ren2)
    del firm; gc.collect()

    keep_base = base[['BoardName1','BoardName2','year',
                      'mask_indirect','mask_direct','mask_no_interlock',
                      'mask_indirect_yoy','mask_direct_yoy','mask_never',
                      'cum_interlock_direct_prev']].copy()

    tmp = keep_base.merge(firm1, on=['BoardName1','year'], how='left', sort=False)\
                   .merge(firm2, on=['BoardName2','year'], how='left', sort=False)

    # force numeric & compact dtype
    for g in groups:
        for suf in ('_1','_2'):
            for kind in ('added','launch'):
                c = f'cum_{entity}_n_{kind}_{g}{suf}'
                if c in tmp.columns:
                    tmp[c] = pd.to_numeric(tmp[c], errors='coerce').astype('float32')

    tmp.sort_values(['BoardName1','BoardName2','year'], inplace=True, kind='mergesort')
    return tmp

# ---------------------- Batch cache: all lags/leads + LAST (ONE PASS per batch) ----------------------
def _build_shift_last_cache(tmp: pd.DataFrame, entity: str, batch: List[str]) -> Dict[str, pd.DataFrame]:
    """
    Build a cache of DataFrames (columns = groups in batch, rows = aligned with tmp),
    containing:
      cur_o1/cur_o2/cur_l1/cur_l2,
      L1_* (lag 1),
      F1/F2/F3 (lead 1..3) for origination,
      LAST_* (pair-level last) for origination and launch.
    All values are float32 to minimize memory.
    """
    # Select matrices for this batch (already float32 in tmp)
    add1 = tmp[[f'cum_{entity}_n_added_{g}_1'  for g in batch]]
    add2 = tmp[[f'cum_{entity}_n_added_{g}_2'  for g in batch]]
    lau1 = tmp[[f'cum_{entity}_n_launch_{g}_1' for g in batch]]
    lau2 = tmp[[f'cum_{entity}_n_launch_{g}_2' for g in batch]]

    g1 = tmp.groupby('BoardName1', sort=False, observed=True)
    g2 = tmp.groupby('BoardName2', sort=False, observed=True)
    gp = tmp.groupby(['BoardName1','BoardName2'], sort=False, observed=True)

    # Origination lags & leads
    L1_o1 = g1[add1.columns].shift(1)
    L1_o2 = g2[add2.columns].shift(1)
    F1_o1 = g1[add1.columns].shift(-1)
    F2_o1 = g1[add1.columns].shift(-2)
    F3_o1 = g1[add1.columns].shift(-3)
    F1_o2 = g2[add2.columns].shift(-1)
    F2_o2 = g2[add2.columns].shift(-2)
    F3_o2 = g2[add2.columns].shift(-3)

    # Launch lags
    L1_l1 = g1[lau1.columns].shift(1)
    L1_l2 = g2[lau2.columns].shift(1)

    # LAST at pair level
    LAST_o1 = gp[add1.columns].transform('last')
    LAST_o2 = gp[add2.columns].transform('last')
    LAST_l1 = gp[lau1.columns].transform('last')
    LAST_l2 = gp[lau2.columns].transform('last')

    # Ensure compact dtype
    to_f32 = lambda df: df.astype('float32', copy=False)

    cache = dict(
        cur_o1=to_f32(add1),  cur_o2=to_f32(add2),
        cur_l1=to_f32(lau1),  cur_l2=to_f32(lau2),

        L1_o1=to_f32(L1_o1),  L1_o2=to_f32(L1_o2),
        F1_o1=to_f32(F1_o1),  F2_o1=to_f32(F2_o1),  F3_o1=to_f32(F3_o1),
        F1_o2=to_f32(F1_o2),  F2_o2=to_f32(F2_o2),  F3_o2=to_f32(F3_o2),

        L1_l1=to_f32(L1_l1),  L1_l2=to_f32(L1_l2),

        LAST_o1=to_f32(LAST_o1), LAST_o2=to_f32(LAST_o2),
        LAST_l1=to_f32(LAST_l1), LAST_l2=to_f32(LAST_l2),
    )
    return cache

def prepare_arrays_fast(
    base_masks: Dict[str, np.ndarray],
    pair_groups_index,
    cache: Dict[str, pd.DataFrame],
    entity: str,
    group_name: str
) -> Dict[str, np.ndarray]:
    """Pull single-column numpy views from the batch cache for this group."""
    col_add_1  = f'cum_{entity}_n_added_{group_name}_1'
    col_add_2  = f'cum_{entity}_n_added_{group_name}_2'
    col_lau_1  = f'cum_{entity}_n_launch_{group_name}_1'
    col_lau_2  = f'cum_{entity}_n_launch_{group_name}_2'

    # Arrays (no copy; .values returns view)
    cur_o1 = cache['cur_o1'][col_add_1].values
    cur_o2 = cache['cur_o2'][col_add_2].values

    arr = dict(
        cur_o1=cur_o1, cur_o2=cur_o2,

        L1_o1 = cache['L1_o1'][col_add_1].values,
        L1_o2 = cache['L1_o2'][col_add_2].values,
        F1_o1 = cache['F1_o1'][col_add_1].values,
        F2_o1 = cache['F2_o1'][col_add_1].values,
        F3_o1 = cache['F3_o1'][col_add_1].values,
        F1_o2 = cache['F1_o2'][col_add_2].values,
        F2_o2 = cache['F2_o2'][col_add_2].values,
        F3_o2 = cache['F3_o2'][col_add_2].values,

        L1_l1 = cache['L1_l1'][col_lau_1].values,
        L1_l2 = cache['L1_l2'][col_lau_2].values,

        LAST_o1 = cache['LAST_o1'][col_add_1].values,
        LAST_o2 = cache['LAST_o2'][col_add_2].values,
        LAST_l1 = cache['LAST_l1'][col_lau_1].values,
        LAST_l2 = cache['LAST_l2'][col_lau_2].values,

        mask_indirect     = base_masks['mask_indirect'],
        mask_direct       = base_masks['mask_direct'],
        mask_none         = base_masks['mask_none'],
        mask_indirect_yoy = base_masks['mask_indirect_yoy'],
        mask_direct_yoy   = base_masks['mask_direct_yoy'],
        mask_never        = base_masks['mask_never'],
    )

    # Causal flags (pairwise monotone built locally; no extra groupby)
    ok1, ok2 = _compute_causal_flags_for_pairs(
        pair_groups_index,
        cache['cur_o1'][col_add_1].values, cache['cur_l1'][col_lau_1].values,
        cache['cur_o2'][col_add_2].values, cache['cur_l2'][col_lau_2].values
    )
    arr['ok1'] = ok1
    arr['ok2'] = ok2
    return arr

# ---------------------- Bundle counts (AB + RN; directional b7–b10) ----------------------
def compute_bundle_counts(arr: Dict[str, np.ndarray], base_mask: np.ndarray) -> List[int]:
    L1_o1, L1_o2 = arr['L1_o1'], arr['L1_o2']
    L1_l1, L1_l2 = arr['L1_l1'], arr['L1_l2']
    cur_o1, cur_o2 = arr['cur_o1'], arr['cur_o2']
    F1_o1, F2_o1, F3_o1 = arr['F1_o1'], arr['F2_o1'], arr['F3_o1']
    F1_o2, F2_o2, F3_o2 = arr['F1_o2'], arr['F2_o2'], arr['F3_o2']
    LAST_o1, LAST_o2, LAST_l1, LAST_l2 = arr['LAST_o1'], arr['LAST_o2'], arr['LAST_l1'], arr['LAST_l2']
    ok1, ok2 = arr['ok1'], arr['ok2']

    mask_na_orig   = (~np.isnan(L1_o1)) & (~np.isnan(L1_o2))
    mask_na_launch = (~np.isnan(L1_l1)) & (~np.isnan(L1_l2))
    mask_na_future = (~np.isnan(F3_o1)) & (~np.isnan(F3_o2))
    both_inexp_lag = (np.nan_to_num(L1_o1, nan=-1) == 0) & (np.nan_to_num(L1_o2, nan=-1) == 0)

    starts1_t_to_t2 = ((cur_o1 > L1_o1) | (F1_o1 > L1_o1) | (F2_o1 > L1_o1) | (F3_o1 > L1_o1))
    starts2_t_to_t2 = ((cur_o2 > L1_o2) | (F1_o2 > L1_o2) | (F2_o2 > L1_o2) | (F3_o2 > L1_o2))
    starts1_by_last = (LAST_o1 > L1_o1)
    starts2_by_last = (LAST_o2 > L1_o2)

    launched1_by_last = (LAST_l1 > L1_l1)
    launched2_by_last = (LAST_l2 > L1_l2)

    either_starts_t_to_t2_and_launched = (
        (starts1_t_to_t2 & launched1_by_last & ok1) |
        (starts2_t_to_t2 & launched2_by_last & ok2)
    )
    either_starts_by_last = (starts1_by_last | starts2_by_last)

    b_second_base = (
        mask_na_orig & mask_na_launch &
        (((L1_l1 == 0) & (L1_o2 == 0)) | ((L1_o1 == 0) & (L1_l2 == 0)))
    )

    # a.*
    a1  = base_mask & mask_na_orig & (((L1_o1 > 0) & (L1_o2 == 0)) | ((L1_o1 == 0) & (L1_o2 > 0)))
    a2  = base_mask & mask_na_orig & (
          (((L1_o1 > 0) & (L1_o2 == 0) & (cur_o2 > 0)) |
           ((L1_o1 == 0) & (L1_o2 > 0) & (cur_o1 > 0))))
    a3  = base_mask & mask_na_orig & mask_na_future & (
          (((L1_o1 > 0) & (L1_o2 == 0) & (F3_o2 > 0)) |
           ((L1_o1 == 0) & (L1_o2 > 0) & (F3_o1 > 0))))
    a4  = base_mask & mask_na_orig & mask_na_future & mask_na_launch & (
          ((L1_o1 > 0) & (L1_o2 == 0) & starts2_t_to_t2 & launched2_by_last & ok2) |
          ((L1_o1 == 0) & (L1_o2 > 0) & starts1_t_to_t2 & launched1_by_last & ok1))
    a5  = base_mask & mask_na_orig & mask_na_future & (
          ((L1_o1 > 0) & (L1_o2 == 0) & starts2_by_last) |
          ((L1_o1 == 0) & (L1_o2 > 0) & starts1_by_last))
    a6  = base_mask & mask_na_orig & both_inexp_lag
    a7  = base_mask & mask_na_orig & both_inexp_lag & ((cur_o1 > 0) | (cur_o2 > 0))
    a8  = base_mask & mask_na_orig & mask_na_future & both_inexp_lag & ((F3_o1 > 0) | (F3_o2 > 0))
    a9  = base_mask & mask_na_orig & mask_na_future & mask_na_launch & both_inexp_lag & either_starts_t_to_t2_and_launched
    a10 = base_mask & mask_na_orig & mask_na_future & both_inexp_lag & either_starts_by_last

    # b1..b5
    b1 = base_mask & mask_na_orig & mask_na_launch & (
         ((L1_l1 > 0) & (L1_o2 == 0)) | ((L1_o1 == 0) & (L1_l2 > 0)))
    b2 = base_mask & mask_na_orig & mask_na_launch & (
         (((L1_l1 > 0) & (L1_o2 == 0) & (cur_o2 > 0)) |
          ((L1_o1 == 0) & (L1_l2 > 0) & (cur_o1 > 0))))
    b3 = base_mask & mask_na_orig & mask_na_launch & mask_na_future & (
         (((L1_l1 > 0) & (L1_o2 == 0) & (F3_o2 > 0)) |
          ((L1_o1 == 0) & (L1_l2 > 0) & (F3_o1 > 0))))
    b4 = base_mask & mask_na_orig & mask_na_launch & mask_na_future & (
         ((L1_l1 > 0) & (L1_o2 == 0) & starts2_t_to_t2 & launched2_by_last & ok2) |
         ((L1_o1 == 0) & (L1_l2 > 0) & starts1_t_to_t2 & launched1_by_last & ok1))
    b5 = base_mask & mask_na_orig & mask_na_launch & mask_na_future & (
         ((L1_l1 > 0) & (L1_o2 == 0) & starts2_by_last) |
         ((L1_o1 == 0) & (L1_l2 > 0) & starts1_by_last))

    # b6..b10 (directional & symmetric)
    b6 = base_mask & b_second_base
    b7 = base_mask & mask_na_orig & mask_na_launch & (
         ((L1_l1 == 0) & (L1_o2 == 0) & (cur_o2 > 0)) |
         ((L1_l2 == 0) & (L1_o1 == 0) & (cur_o1 > 0)))
    b8 = base_mask & mask_na_orig & mask_na_launch & mask_na_future & (
         ((L1_l1 == 0) & (L1_o2 == 0) & (F3_o2 > 0)) |
         ((L1_l2 == 0) & (L1_o1 == 0) & (F3_o1 > 0)))
    b9 = base_mask & mask_na_orig & mask_na_launch & mask_na_future & (
         ((L1_l1 == 0) & (L1_o2 == 0) & (starts2_t_to_t2 & launched2_by_last & ok2)) |
         ((L1_l2 == 0) & (L1_o1 == 0) & (starts1_t_to_t2 & launched1_by_last & ok1)))
    b10 = base_mask & mask_na_orig & mask_na_launch & mask_na_future & (
         ((L1_l1 == 0) & (L1_o2 == 0) & starts2_by_last) |
         ((L1_l2 == 0) & (L1_o1 == 0) & starts1_by_last))

    # rn*
    rn1 = base_mask & mask_na_orig & mask_na_launch & (
          ((L1_o1 > 0) & (L1_o2 == 0) & (L1_l1 == 0)) |
          ((L1_o1 == 0) & (L1_o2 > 0) & (L1_l2 == 0)))
    rn2 = base_mask & mask_na_orig & mask_na_launch & (
          ((L1_o1 > 0) & (L1_o2 == 0) & (L1_l1 == 0) & (cur_o2 > 0)) |
          ((L1_o1 == 0) & (L1_o2 > 0) & (L1_l2 == 0) & (cur_o1 > 0)))
    rn3 = base_mask & mask_na_orig & mask_na_launch & mask_na_future & (
          ((L1_o1 > 0) & (L1_o2 == 0) & (L1_l1 == 0) & (F3_o2 > 0)) |
          ((L1_o1 == 0) & (L1_o2 > 0) & (L1_l2 == 0) & (F3_o1 > 0)))
    rn4 = base_mask & mask_na_orig & mask_na_launch & mask_na_future & (
          ((L1_o1 > 0) & (L1_o2 == 0) & (L1_l1 == 0) & (starts2_t_to_t2 & launched2_by_last & ok2)) |
          ((L1_o1 == 0) & (L1_o2 > 0) & (L1_l2 == 0) & (starts1_t_to_t2 & launched1_by_last & ok1)))
    rn5 = base_mask & mask_na_orig & mask_na_launch & mask_na_future & (
          ((L1_o1 > 0) & (L1_o2 == 0) & (L1_l1 == 0) & (LAST_o2 > L1_o2)) |
          ((L1_o1 == 0) & (L1_o2 > 0) & (L1_l2 == 0) & (LAST_o1 > L1_o1)))

    mats = [a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,
            b1,b2,b3,b4,b5,b6,b7,b8,b9,b10,
            rn1,rn2,rn3,rn4,rn5]
    return [int(m.sum()) for m in mats]

def _counts_shares(counts: List[int], total: int) -> List[float]:
    if total <= 0:
        return [v for c in counts for v in (c, 0.0)]
    return [v for c in counts for v in (c, c/total)]

# ---------------------- Columns & filenames ----------------------
def master_cols():
    cols = ['GroupName']
    cols += ['Total_Indirect_Event_Count','Total_Indirect_Event_Share']
    for i in range(1,11): cols += [f'a.{i}_Count', f'a.{i}_Share']
    for i in range(1,11): cols += [f'b.{i}_Count', f'b.{i}_Share']
    cols += ['ab.rn1_Count','ab.rn1_Share','ab.rn2_Count','ab.rn2_Share','ab.rn3_Count','ab.rn3_Share',
             'ab.rn4_Count','ab.rn4_Share','ab.rn5_Count','ab.rn5_Share']
    cols += ['Total_Direct_Event_Count','Total_Direct_Event_Share']
    for i in range(1,11): cols += [f'e.{i}_Count', f'e.{i}_Share']
    for i in range(1,11): cols += [f'f.{i}_Count', f'f.{i}_Share']
    cols += ['ef.rn1_Count','ef.rn1_Share','ef.rn2_Count','ef.rn2_Share','ef.rn3_Count','ef.rn3_Share',
             'ef.rn4_Count','ef.rn4_Share','ef.rn5_Count','ef.rn5_Share']
    cols += ['Total_NoInterlock_Event_Count','Total_NoInterlock_Event_Share']
    for i in range(1,11): cols += [f'c.{i}_Count', f'c.{i}_Share']
    for i in range(1,11): cols += [f'd.{i}_Count', f'd.{i}_Share']
    cols += ['cd.rn1_Count','cd.rn1_Share','cd.rn2_Count','cd.rn2_Share','cd.rn3_Count','cd.rn3_Share',
             'cd.rn4_Count','cd.rn4_Share','cd.rn5_Count','cd.rn5_Share']
    return cols

def yoy_cols(prefix_total_count: str, prefix_total_share: str):
    cols = ['GroupName', prefix_total_count, prefix_total_share]
    for i in range(1,11): cols += [f'a.{i}_Count', f'a.{i}_Share']
    for i in range(1,11): cols += [f'b.{i}_Count', f'b.{i}_Share']
    cols += ['rn1_Count','rn1_Share','rn2_Count','rn2_Share','rn3_Count','rn3_Share','rn4_Count','rn4_Share','rn5_Count','rn5_Share']
    return cols

def fname(entity: str, base: str) -> str:
    return base if entity == 'disease' else f"therapeutic_{base}"

# ---------------------- Emitters ----------------------
def emit_master(paths, entity, rows):
    out_master = pd.DataFrame(rows, columns=master_cols())
    out_master.rename(columns={'GroupName': 'DiseaseGroup' if entity=='disease' else 'TherapeuticGroup'}, inplace=True)
    master_name = f"full_{'disease' if entity=='disease' else 'therapeutic'}_results_with_all_scenarios.csv"
    out_master.to_csv(os.path.join(paths['output'], master_name), index=False)
    print(f"[{entity}] Saved master: {master_name}")

    key_col = 'DiseaseGroup' if entity=='disease' else 'TherapeuticGroup'

    # indirect legacy
    ab_cols = [key_col,'Total_Indirect_Event_Count','Total_Indirect_Event_Share']
    for i in range(1,11): ab_cols += [f'a.{i}_Count', f'a.{i}_Share']
    for i in range(1,11): ab_cols += [f'b.{i}_Count', f'b.{i}_Share']
    ab_cols += ['ab.rn1_Count','ab.rn1_Share','ab.rn2_Count','ab.rn2_Share','ab.rn3_Count','ab.rn3_Share',
                'ab.rn4_Count','ab.rn4_Share','ab.rn5_Count','ab.rn5_Share']
    df_ab = out_master[ab_cols].copy().rename(columns={
        'Total_Indirect_Event_Count':'Total_Interlock_Event_Count',
        'Total_Indirect_Event_Share':'Total_Interlock_Event_Share'
    })
    f_ab = fname(entity, 'originate_changes_interlock_indirect_with_shares.csv')
    df_ab.to_csv(os.path.join(paths['output'], f_ab), index=False); print(f"[{entity}] {f_ab}")

    # direct legacy
    ef_cols = [key_col,'Total_Direct_Event_Count','Total_Direct_Event_Share']
    for i in range(1,11): ef_cols += [f'e.{i}_Count', f'e.{i}_Share']
    for i in range(1,11): ef_cols += [f'f.{i}_Count', f'f.{i}_Share']
    ef_cols += ['ef.rn1_Count','ef.rn1_Share','ef.rn2_Count','ef.rn2_Share','ef.rn3_Count','ef.rn3_Share',
                'ef.rn4_Count','ef.rn4_Share','ef.rn5_Count','ef.rn5_Share']
    df_ef = out_master[ef_cols].copy()
    rmap = {'Total_Direct_Event_Count':'Total_Direct_Interlock_Event_Count',
            'Total_Direct_Event_Share':'Total_Direct_Interlock_Event_Share'}
    for i in range(1,11):
        rmap[f'e.{i}_Count']=f'a.{i}_Count'; rmap[f'e.{i}_Share']=f'a.{i}_Share'
        rmap[f'f.{i}_Count']=f'b.{i}_Count'; rmap[f'f.{i}_Share']=f'b.{i}_Share'
    df_ef.rename(columns=rmap, inplace=True)
    f_ef = fname(entity, 'originate_changes_interlock_direct_with_shares.csv')
    df_ef.to_csv(os.path.join(paths['output'], f_ef), index=False); print(f"[{entity}] {f_ef}")

    # no interlock legacy
    cd_cols = [key_col,'Total_NoInterlock_Event_Count','Total_NoInterlock_Event_Share']
    for i in range(1,11): cd_cols += [f'c.{i}_Count', f'c.{i}_Share']
    for i in range(1,11): cd_cols += [f'd.{i}_Count', f'd.{i}_Share']
    cd_cols += ['cd.rn1_Count','cd.rn1_Share','cd.rn2_Count','cd.rn2_Share','cd.rn3_Count','cd.rn3_Share',
                'cd.rn4_Count','cd.rn4_Share','cd.rn5_Count','cd.rn5_Share']
    df_cd = out_master[cd_cols].copy()
    f_cd = fname(entity, 'originate_changes_not_interlock_indirect_with_shares.csv')
    df_cd.to_csv(os.path.join(paths['output'], f_cd), index=False); print(f"[{entity}] {f_cd}")

def emit_yoy(paths, entity, indirect_rows, indirect_hist_rows, direct_rows, direct_hist_rows, never_rows):
    df_i = pd.DataFrame(indirect_rows, columns=yoy_cols('Total_Interlock_Event_Count','Total_Interlock_Event_Share'))
    df_i.rename(columns={'GroupName': 'DiseaseGroup' if entity=='disease' else 'TherapeuticGroup'}, inplace=True)
    f_i = fname(entity, 'originate_changes_interlock_indirect_with_shares_YoY_events.csv')
    df_i.to_csv(os.path.join(paths['output'], f_i), index=False); print(f"[{entity}] {f_i}")

    hist_cols = ['GroupName','HistoryBucket','Total_Interlock_Event_Count','Total_Interlock_Event_Share']
    for i in range(1,11): hist_cols += [f'a.{i}_Count', f'a.{i}_Share']
    for i in range(1,11): hist_cols += [f'b.{i}_Count', f'b.{i}_Share']
    hist_cols += ['rn1_Count','rn1_Share','rn2_Count','rn2_Share','rn3_Count','rn3_Share','rn4_Count','rn4_Share','rn5_Count','rn5_Share']
    df_ih = pd.DataFrame(indirect_hist_rows, columns=hist_cols)
    df_ih.rename(columns={'GroupName': 'DiseaseGroup' if entity=='disease' else 'TherapeuticGroup'}, inplace=True)
    f_ih = fname(entity, 'originate_changes_interlock_indirect_with_shares_by_prior_direct_history.csv')
    df_ih.to_csv(os.path.join(paths['output'], f_ih), index=False); print(f"[{entity}] {f_ih}")

    df_d = pd.DataFrame(direct_rows, columns=yoy_cols('Total_Direct_Interlock_Event_Count','Total_Direct_Interlock_Event_Share'))
    df_d.rename(columns={'GroupName': 'DiseaseGroup' if entity=='disease' else 'TherapeuticGroup'}, inplace=True)
    f_d = fname(entity, 'originate_changes_interlock_direct_with_shares_YoY_events.csv')
    df_d.to_csv(os.path.join(paths['output'], f_d), index=False); print(f"[{entity}] {f_d}")

    hist_cols_d = ['GroupName','HistoryBucket','Total_Direct_Interlock_Event_Count','Total_Direct_Interlock_Event_Share']
    for i in range(1,11): hist_cols_d += [f'a.{i}_Count', f'a.{i}_Share']
    for i in range(1,11): hist_cols_d += [f'b.{i}_Count', f'b.{i}_Share']
    hist_cols_d += ['rn1_Count','rn1_Share','rn2_Count','rn2_Share','rn3_Count','rn3_Share','rn4_Count','rn4_Share','rn5_Count','rn5_Share']
    df_dh = pd.DataFrame(direct_hist_rows, columns=hist_cols_d)
    df_dh.rename(columns={'GroupName': 'DiseaseGroup' if entity=='disease' else 'TherapeuticGroup'}, inplace=True)
    f_dh = fname(entity, 'originate_changes_interlock_direct_with_share_by_prior_direct_history.csv')
    df_dh.to_csv(os.path.join(paths['output'], f_dh), index=False); print(f"[{entity}] {f_dh}")

    df_n = pd.DataFrame(never_rows, columns=yoy_cols('Total_NoInterlock_Event_Count','Total_NoInterlock_Event_Share'))
    df_n.rename(columns={'GroupName': 'DiseaseGroup' if entity=='disease' else 'TherapeuticGroup'}, inplace=True)
    f_n = fname(entity, 'originate_changes_not_interlock_with_shares_YoY_events.csv')
    df_n.to_csv(os.path.join(paths['output'], f_n), index=False); print(f"[{entity}] {f_n}")

# ---------------------- Run one entity (BATCHED) ----------------------
def run_entity(paths, base_df: pd.DataFrame, entity: str, groups: List[str], BATCH: int = 20):
    if not groups:
        print(f"[{entity}] No groups detected. Skipped.")
        return

    totals_master = {
        'indirect': int(base_df['mask_indirect'].sum()),
        'direct':   int(base_df['mask_direct'].sum()),
        'none':     int(base_df['mask_no_interlock'].sum())
    }
    mask_indirect_yoy = base_df['mask_indirect_yoy'].to_numpy()
    mask_direct_yoy   = base_df['mask_direct_yoy'].to_numpy()
    mask_never        = base_df['mask_never'].to_numpy()
    hist_no_prior     = (base_df['cum_interlock_direct_prev'] == 0).to_numpy()
    hist_prior        = (base_df['cum_interlock_direct_prev'] > 0).to_numpy()

    master_rows = []
    indirect_rows = []; indirect_hist_rows = []
    direct_rows   = []; direct_hist_rows   = []
    never_rows    = []

    print(f"[{entity}] computing {len(groups)} groups in batches of {BATCH}… (RAM {ram_mb():.1f} MB)")

    for s in range(0, len(groups), BATCH):
        batch = groups[s:s+BATCH]
        tmp = _attach_entity_batch(base_df, paths, entity, batch)
        if tmp is None or tmp.empty:
            continue

        # Precompute all lags/leads/LAST ONCE for this batch
        cache = _build_shift_last_cache(tmp, entity, batch)

        # Grouping for causal flags
        gbp = tmp.groupby(['BoardName1','BoardName2'], sort=False, observed=True)
        pair_indices = gbp.groups

        # Masks (identical for all g in the batch; grab once from tmp)
        base_masks = dict(
            mask_indirect     = tmp['mask_indirect'].to_numpy(),
            mask_direct       = tmp['mask_direct'].to_numpy(),
            mask_none         = tmp['mask_no_interlock'].to_numpy(),
            mask_indirect_yoy = tmp['mask_indirect_yoy'].to_numpy(),
            mask_direct_yoy   = tmp['mask_direct_yoy'].to_numpy(),
            mask_never        = tmp['mask_never'].to_numpy(),
        )

        for g in batch:
            arr = prepare_arrays_fast(base_masks, pair_indices, cache, entity, g)

            # Master (3 scenario bases)
            row = [g]
            c_ind = compute_bundle_counts(arr, arr['mask_indirect']); tot = totals_master['indirect']
            row += [tot, 1.0 if tot else 0.0] + _counts_shares(c_ind, tot)
            c_dir = compute_bundle_counts(arr, arr['mask_direct']);   tot = totals_master['direct']
            row += [tot, 1.0 if tot else 0.0] + _counts_shares(c_dir, tot)
            c_non = compute_bundle_counts(arr, arr['mask_none']);     tot = totals_master['none']
            row += [tot, 1.0 if tot else 0.0] + _counts_shares(c_non, tot)
            master_rows.append(row)

            # YoY overall + history
            tot = int(mask_indirect_yoy.sum())
            indirect_rows.append([g, tot, (1.0 if tot else 0.0)] +
                                 _counts_shares(compute_bundle_counts(arr, mask_indirect_yoy), tot))
            for label, msk in [('no_prior_direct', (mask_indirect_yoy & hist_no_prior)),
                               ('prior_direct',    (mask_indirect_yoy & hist_prior))]:
                tot_h = int(msk.sum())
                indirect_hist_rows.append([g, label, tot_h, (1.0 if tot_h else 0.0)] +
                                          _counts_shares(compute_bundle_counts(arr, msk), tot_h))

            tot = int(mask_direct_yoy.sum())
            direct_rows.append([g, tot, (1.0 if tot else 0.0)] +
                               _counts_shares(compute_bundle_counts(arr, mask_direct_yoy), tot))
            for label, msk in [('no_prior_direct', (mask_direct_yoy & hist_no_prior)),
                               ('prior_direct',    (mask_direct_yoy & hist_prior))]:
                tot_h = int(msk.sum())
                direct_hist_rows.append([g, label, tot_h, (1.0 if tot_h else 0.0)] +
                                        _counts_shares(compute_bundle_counts(arr, msk), tot_h))

            tot = int(mask_never.sum())
            never_rows.append([g, tot, (1.0 if tot else 0.0)] +
                              _counts_shares(compute_bundle_counts(arr, mask_never), tot))

        # cleanup to keep peak RAM down
        del tmp, cache, gbp, pair_indices, base_masks
        gc.collect()
        print(f"  [{entity}] processed {min(s+BATCH, len(groups))}/{len(groups)} groups (RAM {ram_mb():.1f} MB)")

    emit_master(paths, entity, master_rows)
    emit_yoy(paths, entity, indirect_rows, indirect_hist_rows, direct_rows, direct_hist_rows, never_rows)

# ---------------------- Main ----------------------
def main(run_entities=('disease','therapeutic')):
    paths = get_paths()
    print(f"Start (RAM {ram_mb():.1f} MB)")

    df, groups_by_entity = build_base(paths, want_entities=run_entities)

    # Run for requested entities
    for ent in run_entities:
        run_entity(paths, df, ent, groups_by_entity.get(ent, []), BATCH=20)

    print(f"Done. Outputs at: {paths['output']} (RAM {ram_mb():.1f} MB)")

if __name__ == "__main__":
    # You can choose which to run:
    # main(run_entities=('disease',))         # only disease
    # main(run_entities=('therapeutic',))     # only therapeutic
    main(run_entities=('disease','therapeutic'))
