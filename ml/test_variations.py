"""Test rapide: les variations T-1/T-2 sont-elles prédictives ?"""
import pandas as pd
from pathlib import Path
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import cross_val_score

ROOT = Path(__file__).parent.parent
df = pd.read_csv(ROOT / "ml" / "data" / "dataset.csv")

# Garde uniquement les assos avec ≥2 années
multi = df.groupby("siren").filter(lambda g: len(g) >= 2).copy()
multi = multi.sort_values(["siren", "cloture"])
print(f"[info] {len(multi)} lignes sur {multi['siren'].nunique()} assos")

# Pour chaque asso, prend la dernière année avec sa variation par rapport à l'année précédente
def aggregate(group):
    group = group.sort_values("cloture")
    last = group.iloc[-1].copy()
    prev = group.iloc[-2]
    for col in ["ratio_rentabilite", "ratio_solidite", "ratio_liquidite",
                "ratio_resultat_net", "tresorerie", "fonds_propres"]:
        last[f"var_{col}"] = last[col] - prev[col] if pd.notna(last[col]) and pd.notna(prev[col]) else pd.NA
    return last

agg = multi.groupby("siren").apply(aggregate, include_groups=False).reset_index()
print(f"[info] Après aggregation : {len(agg)} assos")
print(f"  - Défaillantes : {(agg['label']==1).sum()}")
print(f"  - Saines       : {(agg['label']==0).sum()}")

# Test 1 : sans variations
features_base = ["ratio_rentabilite", "ratio_solidite", "ratio_liquidite",
                 "ratio_resultat_net", "subv_pct", "cac_certifie"]
# Test 2 : avec variations
features_full = features_base + ["var_ratio_rentabilite", "var_ratio_solidite",
                                  "var_ratio_liquidite", "var_ratio_resultat_net",
                                  "var_tresorerie", "var_fonds_propres"]

for name, feats in [("Sans variations", features_base), ("Avec variations", features_full)]:
    sub = agg.dropna(subset=feats + ["label"])
    if len(sub) < 20:
        print(f"\n{name}: pas assez de données ({len(sub)} cas)")
        continue
    X = sub[feats].values
    y = sub["label"].values
    rf = RandomForestClassifier(n_estimators=200, max_depth=4, random_state=42, n_jobs=-1)
    cv = cross_val_score(rf, X, y, cv=5, scoring="roc_auc")
    print(f"\n{name}: {len(sub)} cas, AUC CV = {cv.mean():.3f} (± {cv.std():.3f})")
