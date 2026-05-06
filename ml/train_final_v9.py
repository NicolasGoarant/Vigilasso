"""
Variante v9 de train_final.py.

Changements vs train_final.py :
- Lit ml/data/dataset_v9.csv (positifs v6 + v8 + age_avant_jugement).
- Ajoute age_avant_jugement aux features META et FULL (RF gère NaN nativement, sklearn>=1.4).
- CLI :
    --filter-age   : drop les positifs avec age_avant_jugement > 3 ans, ET retire la
                     feature age_avant_jugement (variante v9-filtered).
    (sans flag) -> variante v9-with-age (toutes les positifs, age inclus).

Hyperparamètres et split inchangés (RF n_estimators=300, max_depth=6, random_state=42,
test_size=0.20, stratifié).
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
    ap.add_argument("--filter-age", action="store_true",
                    help="Drop positifs avec age > 3 ans et retire age_avant_jugement des features")
    ap.add_argument("--dataset", default=str(ROOT / "ml" / "data" / "dataset_v9.csv"))
    ap.add_argument("--variant-label", default=None)
    ap.add_argument("--json-out", default=None, help="Si fourni, écrit les métriques en JSON")
    args = ap.parse_args()

    label = args.variant_label or ("v9-filtered" if args.filter_age else "v9-with-age")
    print(f"\n########## VARIANT: {label}  (dataset={Path(args.dataset).name}) ##########")
    df = pd.read_csv(args.dataset)

    if args.filter_age:
        n_before = (df["label"] == 1).sum()
        df = df[~((df["label"] == 1) & (df["age_avant_jugement"] > 3))].copy()
        n_after = (df["label"] == 1).sum()
        print(f"[info] --filter-age : drop {n_before - n_after} positifs (age>3) -> {n_after} positifs restants")
        FEATURES_FIN = ["ratio_rentabilite", "ratio_solidite", "ratio_liquidite",
                        "ratio_resultat_net", "subv_pct", "cac_certifie"]
        FEATURES_META = FEATURES_FIN + ["effectif_estime"]
    else:
        FEATURES_FIN = ["ratio_rentabilite", "ratio_solidite", "ratio_liquidite",
                        "ratio_resultat_net", "subv_pct", "cac_certifie"]
        FEATURES_META = FEATURES_FIN + ["effectif_estime", "age_avant_jugement"]

    ape_dummies = pd.get_dummies(df["ape_section"].fillna("XX"), prefix="ape", dtype=int)
    df = pd.concat([df, ape_dummies], axis=1)
    FEATURES_FULL = FEATURES_META + ape_dummies.columns.tolist()

    drop_cols = [c for c in FEATURES_META + ["label"] if c != "age_avant_jugement"]
    df_clean = df.dropna(subset=drop_cols).copy()
    print(f"[info] Après drop NaN : {len(df_clean)} cas "
          f"({(df_clean['label']==1).sum()} défaillantes, {(df_clean['label']==0).sum()} saines)")

    n_pos = (df_clean["label"] == 1).sum()
    saines = df_clean[df_clean["label"] == 0].sample(n=n_pos, random_state=42)
    defaill = df_clean[df_clean["label"] == 1]
    balanced = pd.concat([defaill, saines], ignore_index=True).sample(frac=1, random_state=42)
    print(f"[info] Après équilibrage : {len(balanced)} cas")

    X_fin = balanced[FEATURES_FIN].values
    X_meta = balanced[FEATURES_META].values
    X_full = balanced[FEATURES_FULL].values
    y = balanced["label"].values

    X_fin_tr, X_fin_te, y_tr, y_te = train_test_split(X_fin, y, test_size=0.20, stratify=y, random_state=42)
    X_meta_tr, X_meta_te, _, _ = train_test_split(X_meta, y, test_size=0.20, stratify=y, random_state=42)
    X_full_tr, X_full_te, _, _ = train_test_split(X_full, y, test_size=0.20, stratify=y, random_state=42)

    print(f"[info] Train : {len(X_fin_tr)}  | Test : {len(X_fin_te)}")

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

    eval_model(X_fin_tr, X_fin_te, "FINANCIER", feature_names=FEATURES_FIN)
    eval_model(X_meta_tr, X_meta_te, "FIN+EFFECTIF", feature_names=FEATURES_META)
    rf_full = eval_model(X_full_tr, X_full_te, "FIN+EFFECTIF+APE", feature_names=FEATURES_FULL)

    if "age_avant_jugement" in FEATURES_META:
        idx = FEATURES_META.index("age_avant_jugement")
        meta_imp = sorted(enumerate(rf_full.feature_importances_), key=lambda x: -x[1])
        try:
            full_idx = FEATURES_FULL.index("age_avant_jugement")
            rank = next(i for i, (j, _) in enumerate(meta_imp) if j == full_idx) + 1
            print(f"\n[info] Rang d'age_avant_jugement dans le modèle FIN+EFFECTIF+APE : {rank}/{len(FEATURES_FULL)}")
            results["age_rank_in_full"] = rank
        except (ValueError, StopIteration):
            pass

    if args.json_out:
        Path(args.json_out).parent.mkdir(parents=True, exist_ok=True)
        with open(args.json_out, "w") as f:
            json.dump({"variant": label, "results": results}, f, indent=2, default=str)
        print(f"\n[done] JSON -> {args.json_out}")

if __name__ == "__main__":
    main()
