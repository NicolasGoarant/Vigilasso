"""
Modèle final avec imputation médiane des valeurs manquantes.
Compare drop vs imputation pour mesurer le gain.
"""
import pandas as pd
import numpy as np
from pathlib import Path
from sklearn.model_selection import train_test_split, cross_val_score
from sklearn.ensemble import RandomForestClassifier
from sklearn.impute import SimpleImputer
from sklearn.pipeline import Pipeline
from sklearn.metrics import roc_auc_score, confusion_matrix

ROOT = Path(__file__).parent.parent
df = pd.read_csv(ROOT / "ml" / "data" / "dataset.csv")

FEATURES_NUM = [
    "ratio_rentabilite", "ratio_solidite", "ratio_liquidite",
    "ratio_resultat_net", "subv_pct", "cac_certifie", "effectif_estime"
]

RANDOM_SEED = 42

# One-hot APE comme avant
ape_dummies = pd.get_dummies(df["ape_section"].fillna("XX"), prefix="ape", dtype=int)
df = pd.concat([df, ape_dummies], axis=1)
features_all = FEATURES_NUM + ape_dummies.columns.tolist()

# Variante 1 : DROP (référence)
sub_drop = df.dropna(subset=FEATURES_NUM + ["label"]).copy()
X_drop = sub_drop[features_all].values
y_drop = sub_drop["label"].values

# Variante 2 : IMPUTE médiane
sub_imp = df.dropna(subset=["label"]).copy()
y_imp = sub_imp["label"].values
X_imp_raw = sub_imp[features_all].values

print(f"Cas avec drop NaN     : {len(sub_drop)} ({(y_drop==1).sum()} défaillantes, {(y_drop==0).sum()} saines)")
print(f"Cas avec imputation   : {len(sub_imp)} ({(y_imp==1).sum()} défaillantes, {(y_imp==0).sum()} saines)")

def train_eval(X, y, name):
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.20, stratify=y, random_state=RANDOM_SEED
    )

    pipe = Pipeline([
        ("impute", SimpleImputer(strategy="median")),
        ("rf", RandomForestClassifier(
            class_weight="balanced",
            n_estimators=300, max_depth=8,
            random_state=RANDOM_SEED, n_jobs=-1
        ))
    ])

    cv = cross_val_score(pipe, X_train, y_train, cv=5, scoring="roc_auc")
    pipe.fit(X_train, y_train)
    y_proba = pipe.predict_proba(X_test)[:, 1]
    auc_test = roc_auc_score(y_test, y_proba)

    print(f"\n=== {name} ===")
    print(f"  Train: {len(X_train)} | Test: {len(X_test)}")
    print(f"  AUC CV       : {cv.mean():.3f} ± {cv.std():.3f}")
    print(f"  AUC test     : {auc_test:.3f}")

    y_pred = pipe.predict(X_test)
    cm = confusion_matrix(y_test, y_pred)
    tn, fp, fn, tp = cm.ravel()
    print(f"  Précision défaill. : {tp/(tp+fp):.2%}  | Rappel : {tp/(tp+fn):.2%}")
    print(f"  Matrice : VN={tn} FP={fp} FN={fn} VP={tp}")

    return pipe

# Comparaison
train_eval(X_drop, y_drop, "DROP NaN (348 cas, baseline)")
train_eval(X_imp_raw, y_imp, "IMPUTE médiane (386 cas)")
