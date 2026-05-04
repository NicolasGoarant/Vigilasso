"""
Évaluation rigoureuse : un seul split, équilibrage par sous-échantillonnage des saines.
On compare 3 stratégies sur le MÊME test set.
"""
import pandas as pd
import numpy as np
from pathlib import Path
from sklearn.model_selection import train_test_split, cross_val_score
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import roc_auc_score, confusion_matrix

ROOT = Path(__file__).parent.parent
df = pd.read_csv(ROOT / "ml" / "data" / "dataset.csv")

FEATURES_FIN = ["ratio_rentabilite", "ratio_solidite", "ratio_liquidite",
                "ratio_resultat_net", "subv_pct", "cac_certifie"]
FEATURES_META = FEATURES_FIN + ["effectif_estime"]

ape_dummies = pd.get_dummies(df["ape_section"].fillna("XX"), prefix="ape", dtype=int)
df = pd.concat([df, ape_dummies], axis=1)
FEATURES_FULL = FEATURES_META + ape_dummies.columns.tolist()

# Drop tous les NaN, une fois pour toutes (échantillon stable)
df_clean = df.dropna(subset=FEATURES_META + ["label"]).copy()
print(f"[info] Après drop NaN : {len(df_clean)} cas "
      f"({(df_clean['label']==1).sum()} défaillantes, {(df_clean['label']==0).sum()} saines)")

# Sous-échantillonner les saines pour équilibrer
n_pos = (df_clean["label"]==1).sum()
saines = df_clean[df_clean["label"]==0].sample(n=n_pos, random_state=42)
defaill = df_clean[df_clean["label"]==1]
balanced = pd.concat([defaill, saines], ignore_index=True).sample(frac=1, random_state=42)
print(f"[info] Après équilibrage : {len(balanced)} cas "
      f"({(balanced['label']==1).sum()} défaillantes, {(balanced['label']==0).sum()} saines)")

# Split unique
X_fin = balanced[FEATURES_FIN].values
X_meta = balanced[FEATURES_META].values
X_full = balanced[FEATURES_FULL].values
y = balanced["label"].values

X_fin_tr, X_fin_te, y_tr, y_te = train_test_split(X_fin, y, test_size=0.20, stratify=y, random_state=42)
X_meta_tr, X_meta_te, _, _ = train_test_split(X_meta, y, test_size=0.20, stratify=y, random_state=42)
X_full_tr, X_full_te, _, _ = train_test_split(X_full, y, test_size=0.20, stratify=y, random_state=42)

print(f"[info] Train : {len(X_fin_tr)}  | Test : {len(X_fin_te)}")

def eval_model(X_tr, X_te, name):
    rf = RandomForestClassifier(n_estimators=300, max_depth=6, random_state=42, n_jobs=-1)
    cv = cross_val_score(rf, X_tr, y_tr, cv=5, scoring="roc_auc")
    rf.fit(X_tr, y_tr)
    y_proba = rf.predict_proba(X_te)[:, 1]
    auc_test = roc_auc_score(y_te, y_proba)
    y_pred = rf.predict(X_te)
    cm = confusion_matrix(y_te, y_pred)
    tn, fp, fn, tp = cm.ravel()
    print(f"\n=== {name} ===")
    print(f"  AUC CV   : {cv.mean():.3f} ± {cv.std():.3f}")
    print(f"  AUC test : {auc_test:.3f}")
    print(f"  Précision défaill. : {tp/(tp+fp):.0%}  | Rappel : {tp/(tp+fn):.0%}")
    print(f"  Matrice  : VN={tn} FP={fp} FN={fn} VP={tp}")
    return rf

eval_model(X_fin_tr, X_fin_te, "FINANCIER seul (6 features)")
eval_model(X_meta_tr, X_meta_te, "FINANCIER + EFFECTIF (7 features)")
eval_model(X_full_tr, X_full_te, f"FINANCIER + EFFECTIF + APE ({len(FEATURES_FULL)} features)")
