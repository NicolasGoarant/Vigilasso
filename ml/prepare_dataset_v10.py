"""
Construit dataset_v10.csv : sous-ensemble v10 (400 PDFs ré-extraits) avec
4 nouvelles features non-comptables.

Features ajoutées :
  - cac_certification_qualite (Sonnet, enum 4 valeurs ou null)        -> one-hot
  - concentration_financeurs   (Sonnet, float 0-1 ou null)
  - evolution_subv_3ans        (local, delta moyen pp sur subv_pct sur les
                                3 derniers exercices, null si <2 exercices)
  - evolution_resultat_3ans    (local, delta moyen sur ratio_resultat_net sur
                                les 3 derniers exercices, null si <2 exercices)

Note : delai_publication_jours initialement prévu DROPPÉ (la date de
parution JOAFE n'est pas extractible des PDFs ni des logs existants).

Inputs :
  - data/scores_v10.csv (sortie d'extract_v10.rb)
  - ml/data/dataset_v9.csv (features héritées + historique multi-exercices)

Output :
  - ml/data/dataset_v10.csv (sous-ensemble des 400 PDFs avec toutes les features)

Pas de modification de dataset_v9.csv.
"""

import pandas as pd
import numpy as np
from pathlib import Path

ROOT = Path(__file__).parent.parent
SCORES_V10  = ROOT / "data" / "scores_v10.csv"
DATASET_V9  = ROOT / "ml" / "data" / "dataset_v9.csv"
OUT         = ROOT / "ml" / "data" / "dataset_v10.csv"

CAC_QUALITE_VALUES = [
    "certifie_sans_reserve",
    "certifie_avec_reserve",
    "refus_certification",
    "alerte_continuite_exploitation",
]


def compute_evolution(history_df, feature_col, window=3):
    """
    Pour chaque (siren, cloture) du history_df, calcule la moyenne des deltas
    YoY de feature_col sur les <window> derniers exercices disponibles
    (cloture <= cloture courante), inclusif. Null si <2 exercices.
    """
    history_df = history_df.dropna(subset=[feature_col, "cloture"]).copy()
    history_df["cloture"] = pd.to_datetime(history_df["cloture"], errors="coerce")
    history_df = history_df.dropna(subset=["cloture"])

    out = {}
    for siren, group in history_df.groupby("siren"):
        group = group.sort_values("cloture")
        clotures = group["cloture"].tolist()
        values = group[feature_col].astype(float).tolist()
        for i, c in enumerate(clotures):
            window_vals = values[max(0, i - window + 1) : i + 1]
            if len(window_vals) >= 2:
                deltas = np.diff(window_vals)
                out[(siren, c.strftime("%Y-%m-%d"))] = float(np.mean(deltas))
            else:
                out[(siren, c.strftime("%Y-%m-%d"))] = np.nan
    return out


def main():
    if not SCORES_V10.exists():
        raise SystemExit(f"{SCORES_V10} introuvable. Lance d'abord extract_v10.rb.")

    v10 = pd.read_csv(SCORES_V10, dtype={"siren": str})
    v9  = pd.read_csv(DATASET_V9, dtype={"siren": str})
    print(f"[info] scores_v10.csv : {len(v10)} lignes")
    print(f"[info] dataset_v9.csv : {len(v9)} lignes")

    # === Couverture des nouvelles features Sonnet ===
    v10_ok = v10[v10["error"].isna()].copy()
    n_ok = len(v10_ok)
    print(f"[info] scores_v10 valides (sans error) : {n_ok}")

    cov_cacq = v10_ok["cac_certification_qualite"].notna().sum()
    cov_conc = v10_ok["concentration_financeurs"].notna().sum()
    print(f"[info] Couverture cac_certification_qualite : {cov_cacq}/{n_ok} ({100*cov_cacq/n_ok:.0f}%)")
    print(f"[info] Couverture concentration_financeurs  : {cov_conc}/{n_ok} ({100*cov_conc/n_ok:.0f}%)")
    if n_ok > 0:
        print(f"[info] Distribution cac_certification_qualite :")
        print(v10_ok["cac_certification_qualite"].value_counts(dropna=False).to_string())

    # === Évolutions calculées sur l'historique complet de dataset_v9 ===
    print("\n[info] Calcul des features d'évolution sur l'historique dataset_v9...")
    evol_subv = compute_evolution(v9, "subv_pct")
    evol_resu = compute_evolution(v9, "ratio_resultat_net")

    # === Jointure v10 ⨝ v9 sur fichier pour ramener les features héritées ===
    keep_v9_cols = [
        "fichier", "siren", "cloture", "nom",
        "total_produits", "resultat_exploitation", "resultat_net",
        "fonds_propres", "tresorerie", "total_bilan", "subv_pct",
        "ratio_rentabilite", "ratio_solidite", "ratio_liquidite", "ratio_resultat_net",
        "cac_certifie", "effectif_estime", "ape_section", "departement",
        "age_avant_jugement", "label",
    ]
    v9_sub = v9[keep_v9_cols].copy()
    v10_sub = v10_ok[["fichier", "cac_certification_qualite", "concentration_financeurs"]].copy()
    df = v9_sub.merge(v10_sub, on="fichier", how="inner")
    print(f"\n[info] v10 ⨝ v9 : {len(df)} lignes")

    # === Évolutions sur les rows v10 ===
    df["__cloture_iso"] = pd.to_datetime(df["cloture"], errors="coerce").dt.strftime("%Y-%m-%d")
    df["evolution_subv_3ans"]      = df.apply(lambda r: evol_subv.get((r["siren"], r["__cloture_iso"]), np.nan), axis=1)
    df["evolution_resultat_3ans"]  = df.apply(lambda r: evol_resu.get((r["siren"], r["__cloture_iso"]), np.nan), axis=1)
    df = df.drop(columns=["__cloture_iso"])

    # === One-hot sur cac_certification_qualite ===
    for v in CAC_QUALITE_VALUES:
        df[f"cacq_{v}"] = (df["cac_certification_qualite"] == v).astype(int)

    # === Stats finales ===
    print(f"\n[info] Dataset v10 : {len(df)} lignes")
    print(f"  positifs : {(df['label']==1).sum()}")
    print(f"  saines   : {(df['label']==0).sum()}")
    new_features = [
        "cac_certification_qualite", "concentration_financeurs",
        "evolution_subv_3ans", "evolution_resultat_3ans",
    ]
    print("[info] Couverture nouvelles features (toutes lignes) :")
    for col in new_features:
        n = df[col].notna().sum()
        print(f"  {col:30s} : {n}/{len(df)} ({100*n/len(df):.0f}%)")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(OUT, index=False)
    print(f"\n[done] -> {OUT}")


if __name__ == "__main__":
    main()
