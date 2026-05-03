"""
Compare régression logistique, Random Forest et Gradient Boosting
sur le même split train/test pour mesurer le gain potentiel.
"""

import pandas as pd
import numpy as np
from pathlib import Path
from sklearn.model_selection import train_test_split, cross_val_score
from sklearn.linear_model import LogisticRegression
from sklearn.ensemble import RandomForestClassifier, GradientBoostingClassifier
from sklearn.preprocessing import StandardScaler
from sklearn.pipeline import Pipeline
from sklearn.metrics import roc_auc_score, classification_report, confusion_matrix

ROOT = Path(__file__).parent.parent
DATASET = ROOT / "ml" / "data" / "dataset.csv"

FEATURES = [
    "ratio_rentabilite", "ratio_solidite", "ratio_liquidite", "ratio_resultat_net",
    "subv_pct", "cac_certifie",
]
RANDOM_SEED = 42

def main():
    df = pd.read_csv(DATASET)
    df_clean = df.dropna(subset=FEATURES + ["label"]).copy()
    print(f"[info] {len(df_clean)} cas après drop NaN "
          f"({(df_clean['label']==1).sum()} défaillantes, "
          f"{(df_clean['label']==0).sum()} saines)")

    X = df_clean[FEATURES].values
    y = df_clean["label"].values

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.20, stratify=y, random_state=RANDOM_SEED
    )

    models = {
        "Régression logistique": Pipeline([
            ("scaler", StandardScaler()),
            ("clf", LogisticRegression(max_iter=1000, random_state=RANDOM_SEED, class_weight="balanced"))
        ]),
        "Random Forest": RandomForestClassifier(class_weight="balanced",
            n_estimators=200, max_depth=5, random_state=RANDOM_SEED, n_jobs=-1
        ),
        "Gradient Boosting": GradientBoostingClassifier(
            n_estimators=100, max_depth=3, learning_rate=0.1, random_state=RANDOM_SEED
        ),
    }

    print(f"\n{'Modèle':<25} {'AUC CV (train)':<20} {'AUC test':<12}")
    print("-" * 60)

    results = {}
    for name, model in models.items():
        cv_auc = cross_val_score(model, X_train, y_train, cv=5, scoring="roc_auc")
        model.fit(X_train, y_train)
        y_proba = model.predict_proba(X_test)[:, 1]
        auc_test = roc_auc_score(y_test, y_proba)
        results[name] = (cv_auc, auc_test, model)
        print(f"{name:<25} {cv_auc.mean():.3f} ± {cv_auc.std():.3f}      {auc_test:.3f}")

    # Détail du meilleur modèle
    best_name = max(results, key=lambda k: results[k][1])
    print(f"\n=== Meilleur modèle : {best_name} ===")
    best_cv, best_auc, best_model = results[best_name]

    # Importance des features
    if hasattr(best_model, "feature_importances_"):
        importances = best_model.feature_importances_
    elif hasattr(best_model, "named_steps"):
        importances = np.abs(best_model.named_steps["clf"].coef_[0])
    else:
        importances = None

    if importances is not None:
        print("\nImportance des features (top → bas) :")
        for feat, imp in sorted(zip(FEATURES, importances), key=lambda x: -x[1]):
            print(f"  {feat:25s} : {imp:.3f}")

    # Matrice de confusion
    y_pred = best_model.predict(X_test)
    cm = confusion_matrix(y_test, y_pred)
    print(f"\nMatrice de confusion (seuil 0.5) :")
    print(f"                 prédit_saine  prédit_défaill.")
    print(f"  vraie_saine    {cm[0,0]:>12d}  {cm[0,1]:>15d}")
    print(f"  vraie_défaill. {cm[1,0]:>12d}  {cm[1,1]:>15d}")

if __name__ == "__main__":
    main()
