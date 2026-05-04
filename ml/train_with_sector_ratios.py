"""
Ajoute des ratios relatifs au secteur (APE) :
- Pour chaque ratio financier, calcule l'écart à la médiane sectorielle
- Le modèle apprend à juger une asso par rapport à ses pairs
"""
import pandas as pd
import numpy as np
from pathlib import Path
from sklearn.model_selection import train_test_split, cross_val_score
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import roc_auc_score, confusion_matrix

ROOT = Path(__file__).parent.parent
df = pd.read_csv(ROOT / "ml" / "data" / "dataset.csv")

RATIOS = ["ratio_rentabilite", "ratio_solidite", "ratio_liquidite",
          "ratio_resultat_net", "subv_pct"]

# === 1. Calcul des médianes sectorielles (sur les SAINES uniquement) ===
saines = df[df["label"] == 0]
medianes_par_ape = saines.groupby("ape_section")[RATIOS].median()
print(f"[info] Médianes calculées sur {len(saines)} saines, "
      f"{medianes_par_ape.shape[0]} secteurs APE")

# === 2. Pour chaque ligne, calculer le ratio relatif au secteur ===
for ratio in RATIOS:
    df[f"rel_{ratio}"] = df.apply(
        lambda row: row[ratio] - medianes_par_ape.loc[row["ape_section"], ratio]
        if row["ape_section"] in medianes_par_ape.index and pd.notna(row[ratio])
        else np.nan,
        axis=1
    )

# === 3. Préparation features ===
FEATURES_BASE = RATIOS + ["cac_certifie", "effectif_estime"]
FEATURES_REL  = FEATURES_BASE + [f"rel_{r}" for r in RATIOS]
ape_dummies = pd.get_dummies(df["ape_section"].fillna("XX"), prefix="ape", dtype=int)
df = pd.concat([df, ape_dummies], axis=1)
FEATURES_FULL = FEATURES_REL + ape_dummies.columns.tolist()

# === 4. Drop NaN, équilibrage ===
df_clean = df.dropna(subset=FEATURES_REL + ["label"]).copy()
print(f"[info] Après drop NaN : {len(df_clean)} cas "
      f"({(df_clean['label']==1).sum()} défaillantes, {(df_clean['label']==0).sum()} saines)")

n_pos = (df_clean["label"]==1).sum()
saines_sub = df_clean[df_clean["label"]==0].sample(n=n_pos, random_state=42)
defaill = df_clean[df_clean["label"]==1]
balanced = pd.concat([defaill, saines_sub], ignore_index=True).sample(frac=1, random_state=42)
print(f"[info] Après équilibrage : {len(balanced)} cas")

y = balanced["label"].values
X_base = balanced[FEATURES_BASE].values
X_rel  = balanced[FEATURES_REL].values
X_full = balanced[FEATURES_FULL].values

X_b_tr, X_b_te, y_tr, y_te = train_test_split(X_base, y, test_size=0.20, stratify=y, random_state=42)
X_r_tr, X_r_te, _, _      = train_test_split(X_rel,  y, test_size=0.20, stratify=y, random_state=42)
X_f_tr, X_f_te, _, _      = train_test_split(X_full, y, test_size=0.20, stratify=y, random_state=42)

print(f"[info] Train : {len(X_b_tr)}  | Test : {len(X_b_te)}")

def eval_model(X_tr, X_te, name, n_features):
    rf = RandomForestClassifier(n_estimators=300, max_depth=6, random_state=42, n_jobs=-1)
    cv = cross_val_score(rf, X_tr, y_tr, cv=5, scoring="roc_auc")
    rf.fit(X_tr, y_tr)
    y_proba = rf.predict_proba(X_te)[:, 1]
    auc_test = roc_auc_score(y_te, y_proba)
    y_pred = rf.predict(X_te)
    cm = confusion_matrix(y_te, y_pred)
    tn, fp, fn, tp = cm.ravel()
    print(f"\n=== {name} ({n_features} features) ===")
    print(f"  AUC CV   : {cv.mean():.3f} +/- {cv.std():.3f}")
    print(f"  AUC test : {auc_test:.3f}")
    if (tp+fp) > 0 and (tp+fn) > 0:
        print(f"  Précision défaill. : {tp/(tp+fp):.0%}  | Rappel : {tp/(tp+fn):.0%}")
    print(f"  Matrice  : VN={tn} FP={fp} FN={fn} VP={tp}")
    return rf, y_proba

# Comparaison
eval_model(X_b_tr, X_b_te, "BASELINE (ratios bruts + effectif)", len(FEATURES_BASE))
eval_model(X_r_tr, X_r_te, "+ RATIOS RELATIFS au secteur", len(FEATURES_REL))
rf_full, _ = eval_model(X_f_tr, X_f_te, "+ APE one-hot", len(FEATURES_FULL))

# Importance des features
print(f"\n  Top 10 features importantes du meilleur modèle :")
imp = sorted(zip(FEATURES_FULL, rf_full.feature_importances_), key=lambda x: -x[1])[:10]
for feat, val in imp:
    print(f"    {feat:30s} : {val:.3f}")
