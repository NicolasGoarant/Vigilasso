"""
Variante v10 de train_final.py.

Compare v9-filtered (baseline, dataset_v9.csv avec drop age>3) à v10
(dataset_v10.csv, sous-ensemble 400 PDFs avec 4 nouvelles features).

Important : pour rester comparable, la baseline v9-filtered est restreinte
au MÊME sous-ensemble de fichiers que v10 (inner join sur fichier), histoire
que la différence vienne des features et pas du sample.

Pipelines comparés (les 5 du plan) :
  - FINANCIER (6 ratios comptables)
  - +EFFECTIF
  - +APE one-hot
  - +RATIOS_RELATIFS
  - FULL (= +RATIOS_RELATIFS + APE)

Hyperparamètres : RF 300 arbres, max_depth=6, random_state=42, split 80/20
stratifié, équilibrage par sous-échantillonnage des saines.

Features candidates v10 :
  - cac_certification_qualite (one-hot via 4 colonnes cacq_*)
  - concentration_financeurs
  - evolution_subv_3ans
  - evolution_resultat_3ans

Toute feature avec >70% de NaN sur les positifs (= drop seuil utilisateur)
est retirée des candidats AVANT entraînement et notée dans le log.
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


def filter_age3(df):
    """Applique la stratégie v9-filtered : drop positifs age>3."""
    return df[~((df["label"] == 1) & (df["age_avant_jugement"] > 3))].copy()


def select_new_features(df, label_col="label", null_threshold=0.70):
    """
    Retire les groupes de features avec >threshold de NaN sur les positifs
    (parent feature, pas la one-hot).
    Renvoie la liste des colonnes retenues + un log dict.
    """
    pos = df[df[label_col] == 1]
    retained_cols = []
    drop_log = {}
    for parent, cols in NEW_FEATURE_GROUPS.items():
        n_pos = len(pos)
        n_nan = pos[parent].isna().sum() if parent in pos.columns else n_pos
        frac_nan = n_nan / n_pos if n_pos else 1.0
        if frac_nan > null_threshold:
            drop_log[parent] = f"{frac_nan*100:.0f}% NaN sur positifs (>{int(null_threshold*100)}%) -> DROP"
        else:
            drop_log[parent] = f"{frac_nan*100:.0f}% NaN sur positifs -> KEEP"
            retained_cols.extend(cols)
    return retained_cols, drop_log


def build_features(df, ape_dummies_cols, base_fin):
    """Applique les 5 pipelines."""
    pipelines = {}
    pipelines["FINANCIER"]            = base_fin
    pipelines["+EFFECTIF"]            = base_fin + ["effectif_estime"]
    pipelines["+APE"]                 = base_fin + ["effectif_estime"] + ape_dummies_cols
    return pipelines


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

    BASE_FIN = ["ratio_rentabilite", "ratio_solidite", "ratio_liquidite",
                "ratio_resultat_net", "subv_pct", "cac_certifie"]
    BASE_FIN_EFF = BASE_FIN + ["effectif_estime"]
    ape_dummies = pd.get_dummies(df["ape_section"].fillna("XX"), prefix="ape", dtype=int)
    df = pd.concat([df, ape_dummies], axis=1)
    ape_cols = ape_dummies.columns.tolist()

    fin = BASE_FIN + extra_features
    fin_eff = BASE_FIN_EFF + extra_features
    fin_eff_ape = BASE_FIN_EFF + ape_cols + extra_features

    drop_subset = list(set(BASE_FIN_EFF + ["label"]))  # ne drop pas sur les nouvelles features (NaN ok via RF natif)
    df_clean = df.dropna(subset=drop_subset).copy()
    print(f"[info] Après drop NaN sur features comptables : {len(df_clean)} cas "
          f"({(df_clean['label']==1).sum()} pos / {(df_clean['label']==0).sum()} neg)")

    n_pos = (df_clean["label"] == 1).sum()
    saines = df_clean[df_clean["label"] == 0]
    if len(saines) >= n_pos:
        saines = saines.sample(n=n_pos, random_state=42)
    defaill = df_clean[df_clean["label"] == 1]
    balanced = pd.concat([defaill, saines], ignore_index=True).sample(frac=1, random_state=42)
    print(f"[info] Après équilibrage : {len(balanced)} cas")

    y = balanced["label"].values
    X_fin     = balanced[fin].values
    X_fin_eff = balanced[fin_eff].values
    X_fin_ape = balanced[fin_eff_ape].values

    X_fin_tr, X_fin_te, y_tr, y_te = train_test_split(X_fin, y, test_size=0.20, stratify=y, random_state=42)
    X_e_tr,   X_e_te,   _, _       = train_test_split(X_fin_eff, y, test_size=0.20, stratify=y, random_state=42)
    X_a_tr,   X_a_te,   _, _       = train_test_split(X_fin_ape, y, test_size=0.20, stratify=y, random_state=42)

    print(f"[info] Train : {len(X_fin_tr)}  | Test : {len(X_fin_te)}")

    _, r1 = eval_pipeline(X_fin_tr, X_fin_te, y_tr, y_te, "FINANCIER", feature_names=fin)
    _, r2 = eval_pipeline(X_e_tr, X_e_te, y_tr, y_te, "+EFFECTIF", feature_names=fin_eff)
    rf3, r3 = eval_pipeline(X_a_tr, X_a_te, y_tr, y_te, "+APE", feature_names=fin_eff_ape)

    results_acc[variant_name] = {
        "FINANCIER": r1, "+EFFECTIF": r2, "+APE": r3,
        "n_train": int(len(X_fin_tr)), "n_test": int(len(X_fin_te)),
    }
    return rf3


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json-out", default="/tmp/v10_runs/v10_final.json")
    args = ap.parse_args()

    df_v10 = pd.read_csv(ROOT / "ml" / "data" / "dataset_v10.csv", dtype={"siren": str})
    df_v9  = pd.read_csv(ROOT / "ml" / "data" / "dataset_v9.csv",  dtype={"siren": str})
    print(f"[info] dataset_v10.csv : {len(df_v10)}")
    print(f"[info] dataset_v9.csv  : {len(df_v9)}")

    # Restreint v9 aux mêmes fichiers que v10 (comparaison strictement comparable)
    fichiers_v10 = set(df_v10["fichier"])
    df_v9_sub = df_v9[df_v9["fichier"].isin(fichiers_v10)].copy()
    print(f"[info] dataset_v9 restreint au sample v10 : {len(df_v9_sub)}")

    # Sélection des nouvelles features (drop si >70% null sur positifs)
    extra_cols, drop_log = select_new_features(df_v10)
    print("\n[info] Sélection des nouvelles features :")
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
