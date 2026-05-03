"""
Entraîne avec features financières + métadonnées INSEE (effectif, secteur, département).
Compare au baseline sans métadonnées.
"""
import pandas as pd
import numpy as np
from pathlib import Path
from sklearn.model_selection import train_test_split, cross_val_score
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import roc_auc_score, confusion_matrix, classification_report

ROOT = Path(__file__).parent.parent
df = pd.read_csv(ROOT / "ml" / "data" / "dataset.csv")

FEATURES_BASE = [
    "ratio_rentabilite", "ratio_solidite", "ratio_liquidite",
    "ratio_resultat_net", "subv_pct", "cac_certifie"
]

FEATURES_META = FEATURES_BASE + ["effectif_estime"]

RANDOM_SEED = 42

def evaluate(name, features, drop_na=True):
    if drop_na:
        sub = df.dropna(subset=features + ["label"]).copy()
    else:
        sub = df.dropna(subset=["label"]).copy()
        sub[features] = sub[features].fillna(sub[features].median())

    X = sub[features].values
    y = sub["label"].values
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.20, stratify=y, random_state=RANDOM_SEED
    )

    rf = RandomForestClassifier(
        class_weight="balanced",
        n_estimators=300, max_depth=6,
        random_state=RANDOM_SEED, n_jobs=-1
    )
    cv = cross_val_score(rf, X_train, y_train, cv=5, scoring="roc_auc")
    rf.fit(X_train, y_train)
    y_proba = rf.predict_proba(X_test)[:, 1]
    auc_test = roc_auc_score(y_test, y_proba)

    print(f"\n=== {name} ===")
    print(f"  Cas (après drop NaN) : {len(sub)} | train {len(X_train)} | test {len(X_test)}")
    print(f"  AUC CV (train) : {cv.mean():.3f} ± {cv.std():.3f}")
    print(f"  AUC test       : {auc_test:.3f}")
    return rf, X_test, y_test, y_proba

# Baseline : 6 features financières
evaluate("BASELINE (6 features financières)", FEATURES_BASE)

# Avec effectif estimé
evaluate("AVEC EFFECTIF (7 features)", FEATURES_META)

# Avec one-hot APE section
df_ape = df.copy()
ape_dummies = pd.get_dummies(df_ape["ape_section"].fillna("XX"), prefix="ape", dtype=int)
df_ape = pd.concat([df_ape, ape_dummies], axis=1)
features_ape = FEATURES_META + ape_dummies.columns.tolist()
sub = df_ape.dropna(subset=FEATURES_META + ["label"]).copy()
X = sub[features_ape].values
y = sub["label"].values
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.20, stratify=y, random_state=RANDOM_SEED)
rf = RandomForestClassifier(class_weight="balanced", n_estimators=300, max_depth=8, random_state=RANDOM_SEED, n_jobs=-1)
cv = cross_val_score(rf, X_train, y_train, cv=5, scoring="roc_auc")
rf.fit(X_train, y_train)
y_proba = rf.predict_proba(X_test)[:, 1]
auc_test = roc_auc_score(y_test, y_proba)
print(f"\n=== AVEC EFFECTIF + APE one-hot ({len(features_ape)} features) ===")
print(f"  Cas : {len(sub)} | train {len(X_train)} | test {len(X_test)}")
print(f"  AUC CV (train) : {cv.mean():.3f} ± {cv.std():.3f}")
print(f"  AUC test       : {auc_test:.3f}")

# Importance des top features
print(f"\n  Top 10 features importantes :")
imp = sorted(zip(features_ape, rf.feature_importances_), key=lambda x: -x[1])[:10]
for feat, val in imp:
    print(f"    {feat:30s} : {val:.3f}")

# Matrice de confusion
y_pred = rf.predict(X_test)
cm = confusion_matrix(y_test, y_pred)
print(f"\n  Matrice de confusion (seuil 0.5) :")
print(f"                   prédit_saine  prédit_défaill.")
print(f"  vraie_saine      {cm[0,0]:>12d}  {cm[0,1]:>15d}")
print(f"  vraie_défaill.   {cm[1,0]:>12d}  {cm[1,1]:>15d}")
