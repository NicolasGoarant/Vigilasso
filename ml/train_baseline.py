"""
Entraîne une régression logistique pour prédire la défaillance.

Compare aux poids du scoring métier actuel.
Réserve 20% en test set pour évaluation honnête.
"""

import pandas as pd
import numpy as np
from pathlib import Path
from sklearn.model_selection import train_test_split, cross_val_score
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler
from sklearn.pipeline import Pipeline
from sklearn.metrics import (
    roc_auc_score, classification_report, confusion_matrix,
    precision_recall_curve
)

ROOT = Path(__file__).parent.parent
DATASET = ROOT / "ml" / "data" / "dataset.csv"

FEATURES = [
    "ratio_rentabilite", "ratio_solidite", "ratio_liquidite", "ratio_resultat_net",
    "subv_pct", "cac_certifie",
]

RANDOM_SEED = 42

def main():
    df = pd.read_csv(DATASET)
    print(f"[info] Dataset chargé : {len(df)} lignes")

    # Drop des lignes avec valeurs manquantes sur les features ML
    df_clean = df.dropna(subset=FEATURES + ["label"]).copy()
    print(f"[info] Après drop NaN : {len(df_clean)} lignes "
          f"({(df_clean['label']==1).sum()} défaillantes, "
          f"{(df_clean['label']==0).sum()} saines)")

    X = df_clean[FEATURES].values
    y = df_clean["label"].values

    # Split 80/20 stratifié
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.20, stratify=y, random_state=RANDOM_SEED
    )
    print(f"[info] Train : {len(X_train)}  | Test : {len(X_test)}")

    # Pipeline : standardisation + régression logistique
    pipe = Pipeline([
        ("scaler", StandardScaler()),
        ("clf", LogisticRegression(max_iter=1000, random_state=RANDOM_SEED))
    ])

    # Cross-validation 5-fold sur le train
    cv_auc = cross_val_score(pipe, X_train, y_train, cv=5, scoring="roc_auc")
    print(f"\n=== Cross-validation 5-fold (train) ===")
    print(f"  AUC moyen : {cv_auc.mean():.3f} (± {cv_auc.std():.3f})")
    print(f"  AUC par fold : {[f'{a:.3f}' for a in cv_auc]}")

    # Entraînement final sur tout le train
    pipe.fit(X_train, y_train)

    # Évaluation sur le test set (qu'on n'a jamais touché)
    y_pred = pipe.predict(X_test)
    y_proba = pipe.predict_proba(X_test)[:, 1]
    auc_test = roc_auc_score(y_test, y_proba)

    print(f"\n=== Évaluation sur test set ({len(X_test)} cas) ===")
    print(f"  AUC : {auc_test:.3f}")
    print(f"\n  Matrice de confusion (seuil 0.5) :")
    cm = confusion_matrix(y_test, y_pred)
    print(f"                 prédit_saine  prédit_défaill.")
    print(f"  vraie_saine    {cm[0,0]:>12d}  {cm[0,1]:>15d}")
    print(f"  vraie_défaill. {cm[1,0]:>12d}  {cm[1,1]:>15d}")
    print(f"\n{classification_report(y_test, y_pred, target_names=['saine', 'défaillante'])}")

    # Poids appris vs poids métier
    print(f"\n=== Poids appris par la régression logistique ===")
    coefs = pipe.named_steps["clf"].coef_[0]
    intercept = pipe.named_steps["clf"].intercept_[0]
    for feat, coef in sorted(zip(FEATURES, coefs), key=lambda x: -abs(x[1])):
        sign = "↑ défaillance" if coef > 0 else "↓ défaillance"
        print(f"  {feat:25s} : {coef:+.3f}  ({sign})")
    print(f"  intercept                 : {intercept:+.3f}")

    # Comparaison avec scoring métier
    print(f"\n=== Comparaison avec le scoring métier actuel ===")
    print(f"  Poids métier (rappel) :")
    print(f"    rentabilite=30, solidite=25, liquidite=20, autonomie=15, gouvernance=10")
    print(f"\n  La régression apprend un signe NÉGATIF pour les features qui PROTÈGENT")
    print(f"  contre la défaillance (rentabilité haute = saine = label 0).")

    # Précision/rappel à différents seuils
    precision, recall, thresholds = precision_recall_curve(y_test, y_proba)
    print(f"\n=== Trade-off précision/rappel sur test set ===")
    for target_recall in [0.5, 0.7, 0.8, 0.9]:
        idx = np.argmin(np.abs(recall[:-1] - target_recall))
        if idx < len(thresholds):
            print(f"  Pour rappel={recall[idx]:.2f} : "
                  f"précision={precision[idx]:.2f}, seuil={thresholds[idx]:.2f}")

if __name__ == "__main__":
    main()
