"""
Variante v10 de train_with_sector_ratios.py.

Compare v9-filtered (baseline, sample restreint v10) à v10 (avec nouvelles
features) sur les pipelines à ratios sectoriels.

Pipelines :
  - BASELINE_RATIOS : ratios bruts + effectif
  - +RATIOS_RELATIFS : + écart à la médiane sectorielle
  - +APE : + APE one-hot

Stratégie de sélection des features identique à train_final_v10 (drop si
>70% null sur positifs).
"""

import argparse
import json
import pandas as pd
import numpy as np
from pathlib import Path
from sklearn.model_selection import train_test_split, cross_val_score
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import roc_auc_score, confusion_matrix, f1_score

ROOT = Path(__file__).parent.parent

CAC_QUALITE_VALUES = [
    "certifie_sans_reserve",
    "certifie_avec_reserve",
    "refus_certification",
    "alerte_continuite_exploitation",
]
NEW_FEATURE_GROUPS = {
    "cac_certification_qualite": [f"cacq_{v}" for v in CAC_QUALITE_VALUES],
    "concentration_financeurs": ["concentration_financeurs"],
    "evolution_subv_3ans": ["evolution_subv_3ans"],
    "evolution_resultat_3ans": ["evolution_resultat_3ans"],
}
RATIOS = ["ratio_rentabilite", "ratio_solidite", "ratio_liquidite",
          "ratio_resultat_net", "subv_pct"]


def filter_age3(df):
    return df[~((df["label"] == 1) & (df["age_avant_jugement"] > 3))].copy()


def select_new_features(df, null_threshold=0.70):
    pos = df[df["label"] == 1]
    retained = []
    log = {}
    for parent, cols in NEW_FEATURE_GROUPS.items():
        n_pos = len(pos)
        n_nan = pos[parent].isna().sum() if parent in pos.columns else n_pos
        frac = n_nan / n_pos if n_pos else 1.0
        if frac > null_threshold:
            log[parent] = f"{frac*100:.0f}% NaN -> DROP"
        else:
            log[parent] = f"{frac*100:.0f}% NaN -> KEEP"
            retained.extend(cols)
    return retained, log


def add_relative_ratios(df, ratios=RATIOS):
    saines = df[df["label"] == 0]
    medianes = saines.groupby("ape_section")[ratios].median()
    for ratio in ratios:
        df[f"rel_{ratio}"] = df.apply(
            lambda row: row[ratio] - medianes.loc[row["ape_section"], ratio]
            if row["ape_section"] in medianes.index and pd.notna(row[ratio])
            else np.nan,
            axis=1
        )
    return df, medianes


def eval_pipeline(X_tr, X_te, y_tr, y_te, name, feature_names=None):
    rf = RandomForestClassifier(n_estimators=300, max_depth=6, random_state=42, n_jobs=-1)
    cv = cross_val_score(rf, X_tr, y_tr, cv=5, scoring="roc_auc")
    rf.fit(X_tr, y_tr)
    y_proba = rf.predict_proba(X_te)[:, 1]
    auc_test = roc_auc_score(y_te, y_proba)
    y_pred = rf.predict(X_te)
    cm = confusion_matrix(y_te, y_pred)
    tn, fp, fn, tp = cm.ravel()
    prec = tp / (tp + fp) if (tp + fp) else 0.0
    rec  = tp / (tp + fn) if (tp + fn) else 0.0
    f1   = f1_score(y_te, y_pred)
    print(f"\n=== {name} ===")
    print(f"  AUC CV   : {cv.mean():.3f} ± {cv.std():.3f}")
    print(f"  AUC test : {auc_test:.3f}")
    print(f"  Précision : {prec:.0%}  | Rappel : {rec:.0%}  | F1 : {f1:.2f}")
    print(f"  Matrice  : VN={tn} FP={fp} FN={fn} VP={tp}")
    out = {
        "auc_cv_mean": float(cv.mean()),
        "auc_cv_std": float(cv.std()),
        "auc_test": float(auc_test),
        "precision": float(prec),
        "recall": float(rec),
        "f1": float(f1),
        "tn": int(tn), "fp": int(fp), "fn": int(fn), "tp": int(tp),
    }
    if feature_names is not None:
        imp = sorted(zip(feature_names, rf.feature_importances_), key=lambda x: -x[1])
        out["feature_importances"] = [(f, float(v)) for f, v in imp]
    return rf, out


def run_variant(df, variant_name, extra_features, results_acc):
    print(f"\n########## VARIANT: {variant_name}  ##########")
    df = filter_age3(df).copy()
    df, _ = add_relative_ratios(df)

    BASE = RATIOS + ["cac_certifie", "effectif_estime"] + extra_features
    REL  = BASE + [f"rel_{r}" for r in RATIOS]
    ape_dummies = pd.get_dummies(df["ape_section"].fillna("XX"), prefix="ape", dtype=int)
    df = pd.concat([df, ape_dummies], axis=1)
    FULL = REL + ape_dummies.columns.tolist()

    drop_subset = [c for c in REL if c not in extra_features] + ["label"]
    df_clean = df.dropna(subset=drop_subset).copy()
    print(f"[info] Après drop NaN sur features comptables : {len(df_clean)}")

    n_pos = (df_clean["label"] == 1).sum()
    saines = df_clean[df_clean["label"] == 0]
    if len(saines) >= n_pos:
        saines = saines.sample(n=n_pos, random_state=42)
    defaill = df_clean[df_clean["label"] == 1]
    balanced = pd.concat([defaill, saines], ignore_index=True).sample(frac=1, random_state=42)
    print(f"[info] Après équilibrage : {len(balanced)}")

    y = balanced["label"].values
    X_b = balanced[BASE].values
    X_r = balanced[REL].values
    X_f = balanced[FULL].values

    X_b_tr, X_b_te, y_tr, y_te = train_test_split(X_b, y, test_size=0.20, stratify=y, random_state=42)
    X_r_tr, X_r_te, _, _       = train_test_split(X_r, y, test_size=0.20, stratify=y, random_state=42)
    X_f_tr, X_f_te, _, _       = train_test_split(X_f, y, test_size=0.20, stratify=y, random_state=42)

    print(f"[info] Train : {len(X_b_tr)}  | Test : {len(X_b_te)}")

    _, r1 = eval_pipeline(X_b_tr, X_b_te, y_tr, y_te, "BASELINE_RATIOS", feature_names=BASE)
    _, r2 = eval_pipeline(X_r_tr, X_r_te, y_tr, y_te, "+RATIOS_RELATIFS", feature_names=REL)
    _, r3 = eval_pipeline(X_f_tr, X_f_te, y_tr, y_te, "+APE", feature_names=FULL)

    results_acc[variant_name] = {
        "BASELINE_RATIOS": r1, "+RATIOS_RELATIFS": r2, "+APE": r3,
        "n_train": int(len(X_b_tr)), "n_test": int(len(X_b_te)),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json-out", default="/tmp/v10_runs/v10_sector.json")
    args = ap.parse_args()

    df_v10 = pd.read_csv(ROOT / "ml" / "data" / "dataset_v10.csv", dtype={"siren": str})
    df_v9  = pd.read_csv(ROOT / "ml" / "data" / "dataset_v9.csv",  dtype={"siren": str})

    fichiers_v10 = set(df_v10["fichier"])
    df_v9_sub = df_v9[df_v9["fichier"].isin(fichiers_v10)].copy()
    print(f"[info] v10={len(df_v10)} / v9-restreint={len(df_v9_sub)}")

    extra_cols, drop_log = select_new_features(df_v10)
    print("\n[info] Sélection nouvelles features :")
    for k, v in drop_log.items():
        print(f"   {k:30s} : {v}")
    print(f"[info] Colonnes retenues : {extra_cols}")

    results = {}
    run_variant(df_v9_sub, "v9-filtered (sample restreint v10)", extra_features=[], results_acc=results)
    run_variant(df_v10,    "v10 (sample + nouvelles features)",  extra_features=extra_cols, results_acc=results)

    Path(args.json_out).parent.mkdir(parents=True, exist_ok=True)
    with open(args.json_out, "w") as f:
        json.dump({"results": results, "feature_drop_log": drop_log,
                   "extra_features_used": extra_cols}, f, indent=2, default=str)
    print(f"\n[done] JSON -> {args.json_out}")


if __name__ == "__main__":
    main()
