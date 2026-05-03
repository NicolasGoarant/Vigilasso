"""
Analyse précision/rappel à différents seuils pour le meilleur modèle.
Aide à choisir le seuil opérationnel selon le cas d'usage.
"""
import pandas as pd
import numpy as np
from pathlib import Path
from sklearn.model_selection import train_test_split
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import precision_recall_curve, confusion_matrix

ROOT = Path(__file__).parent.parent
df = pd.read_csv(ROOT / "ml" / "data" / "dataset.csv")

FEATURES = ["ratio_rentabilite", "ratio_solidite", "ratio_liquidite",
            "ratio_resultat_net", "subv_pct", "cac_certifie"]
RANDOM_SEED = 42

df_clean = df.dropna(subset=FEATURES + ["label"]).copy()
X = df_clean[FEATURES].values
y = df_clean["label"].values
X_train, X_test, y_train, y_test = train_test_split(
    X, y, test_size=0.20, stratify=y, random_state=RANDOM_SEED
)

model = RandomForestClassifier(
    class_weight="balanced",
    n_estimators=200, max_depth=5, random_state=RANDOM_SEED, n_jobs=-1
)
model.fit(X_train, y_train)
y_proba = model.predict_proba(X_test)[:, 1]

precision, recall, thresholds = precision_recall_curve(y_test, y_proba)

print(f"Test set : {len(y_test)} cas ({y_test.sum()} défaillantes, {(y_test==0).sum()} saines)\n")
print(f"{'Seuil':<8} {'Précision':<11} {'Rappel':<8} {'Vrais pos.':<11} {'Faux pos.':<11} {'Manqués':<10}")
print("-" * 60)

for seuil in [0.3, 0.4, 0.5, 0.6, 0.7, 0.8]:
    y_pred = (y_proba >= seuil).astype(int)
    cm = confusion_matrix(y_test, y_pred, labels=[0, 1])
    tn, fp, fn, tp = cm.ravel()
    p = tp / (tp + fp) if (tp + fp) > 0 else 0
    r = tp / (tp + fn) if (tp + fn) > 0 else 0
    print(f"{seuil:<8.2f} {p:<11.2%} {r:<8.2%} {tp:<11d} {fp:<11d} {fn:<10d}")

print(f"\n=== Lecture métier ===")
print(f"Pour un service Vie Associative qui suit 200 assos :")
print(f"  - Seuil 0.5 = environ {int(200 * (y_proba >= 0.5).mean())} alertes/an, dont X% fondées (voir tableau)")
print(f"  - Seuil 0.7 = environ {int(200 * (y_proba >= 0.7).mean())} alertes/an, dont X% fondées (voir tableau)")
