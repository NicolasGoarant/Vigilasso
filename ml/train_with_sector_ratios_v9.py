"""
Variante v9 de train_with_sector_ratios.py.

Changements vs train_with_sector_ratios.py :
- Lit ml/data/dataset_v9.csv.
- Ajoute age_avant_jugement aux features (RATIOS REL et FULL).
- CLI :
    --filter-age   : drop les positifs avec age_avant_jugement > 3 ans, ET retire la
                     feature age_avant_jugement (variante v9-filtered).
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

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--filter-age", action="store_true")
    ap.add_argument("--dataset", default=str(ROOT / "ml" / "data" / "dataset_v9.csv"))
    ap.add_argument("--variant-label", default=None)
    ap.add_argument("--json-out", default=None)
    args = ap.parse_args()

    label = args.variant_label or ("v9-filtered" if args.filter_age else "v9-with-age")
    print(f"\n########## VARIANT: {label}  (dataset={Path(args.dataset).name}) ##########")
    df = pd.read_csv(args.dataset)

    if args.filter_age:
        n_before = (df["label"] == 1).sum()
        df = df[~((df["label"] == 1) & (df["age_avant_jugement"] > 3))].copy()
        n_after = (df["label"] == 1).sum()
        print(f"[info] --filter-age : {n_before} -> {n_after} positifs")
        EXTRA = []
    else:
        EXTRA = ["age_avant_jugement"]

    RATIOS = ["ratio_rentabilite", "ratio_solidite", "ratio_liquidite",
              "ratio_resultat_net", "subv_pct"]

    saines = df[df["label"] == 0]
    medianes = saines.groupby("ape_section")[RATIOS].median()
    print(f"[info] Médianes calculées sur {len(saines)} saines, {medianes.shape[0]} secteurs APE")

    for ratio in RATIOS:
        df[f"rel_{ratio}"] = df.apply(
            lambda row: row[ratio] - medianes.loc[row["ape_section"], ratio]
            if row["ape_section"] in medianes.index and pd.notna(row[ratio])
            else np.nan,
            axis=1
        )

    FEATURES_BASE = RATIOS + ["cac_certifie", "effectif_estime"] + EXTRA
    FEATURES_REL  = FEATURES_BASE + [f"rel_{r}" for r in RATIOS]
    ape_dummies = pd.get_dummies(df["ape_section"].fillna("XX"), prefix="ape", dtype=int)
    df = pd.concat([df, ape_dummies], axis=1)
    FEATURES_FULL = FEATURES_REL + ape_dummies.columns.tolist()

    drop_cols = [c for c in FEATURES_REL + ["label"] if c != "age_avant_jugement"]
    df_clean = df.dropna(subset=drop_cols).copy()
    print(f"[info] Après drop NaN : {len(df_clean)} cas "
          f"({(df_clean['label']==1).sum()} défaillantes, {(df_clean['label']==0).sum()} saines)")

    n_pos = (df_clean["label"] == 1).sum()
    saines_sub = df_clean[df_clean["label"] == 0].sample(n=n_pos, random_state=42)
    defaill = df_clean[df_clean["label"] == 1]
    balanced = pd.concat([defaill, saines_sub], ignore_index=True).sample(frac=1, random_state=42)
    print(f"[info] Après équilibrage : {len(balanced)}")

    y = balanced["label"].values
    X_base = balanced[FEATURES_BASE].values
    X_rel  = balanced[FEATURES_REL].values
    X_full = balanced[FEATURES_FULL].values

    X_b_tr, X_b_te, y_tr, y_te = train_test_split(X_base, y, test_size=0.20, stratify=y, random_state=42)
    X_r_tr, X_r_te, _, _      = train_test_split(X_rel,  y, test_size=0.20, stratify=y, random_state=42)
    X_f_tr, X_f_te, _, _      = train_test_split(X_full, y, test_size=0.20, stratify=y, random_state=42)

    print(f"[info] Train : {len(X_b_tr)}  | Test : {len(X_b_te)}")

    results = {}

    def eval_model(X_tr, X_te, name, feature_names=None):
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
        results[name] = {
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
            results[name]["feature_importances"] = [(f, float(v)) for f, v in imp]
        return rf

    eval_model(X_b_tr, X_b_te, "BASELINE_RATIOS", feature_names=FEATURES_BASE)
    eval_model(X_r_tr, X_r_te, "+RATIOS_RELATIFS", feature_names=FEATURES_REL)
    rf_full = eval_model(X_f_tr, X_f_te, "+APE", feature_names=FEATURES_FULL)

    if args.json_out:
        Path(args.json_out).parent.mkdir(parents=True, exist_ok=True)
        with open(args.json_out, "w") as f:
            json.dump({"variant": label, "results": results}, f, indent=2, default=str)
        print(f"\n[done] JSON -> {args.json_out}")

if __name__ == "__main__":
    main()
