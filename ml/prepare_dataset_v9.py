"""
Construit dataset_v9.csv : dataset_v6 + scores_positifs_v8.csv + age_avant_jugement.

Différences vs prepare_dataset.py :
- Inclut data/scores_positifs_v8.csv en plus de scores_positifs.csv (dédoublonnage par
  `fichier`, on garde la version v8 si collision et on logge les écarts de score/niveau).
- Joint bodacc_associations_enrichi.csv sur `siren` pour récupérer la date du jugement
  la plus ancienne par SIREN (= défaillance initiale).
- Calcule age_avant_jugement = (date_jugement - cloture) / 365.25 pour les positifs.
- Pour les saines : age_avant_jugement = NaN (RandomForest sklearn >= 1.4 gère NaN
  nativement). Voir REPORT_v9.md pour la discussion sur le risque de leakage.

Pas de modification de scores_positifs.csv, scores_positifs_v8.csv,
bodacc_associations_enrichi.csv, ni de dataset.csv.
"""

import pandas as pd
import numpy as np
import re
from pathlib import Path

ROOT = Path(__file__).parent.parent
POSITIFS_V6 = ROOT / "data" / "scores_positifs.csv"
POSITIFS_V8 = ROOT / "data" / "scores_positifs_v8.csv"
SAINES      = ROOT / "data" / "scores_saines.csv"
BODACC_META = ROOT / "bodacc_associations_enrichi.csv"
SAINES_META = ROOT / "data" / "saines_enrichi.csv"
SAINES_META_400 = ROOT / "data" / "saines_400_enrichi.csv"
OUT         = ROOT / "ml" / "data" / "dataset_v9.csv"

PATTERN = re.compile(r"^(\d{9})_(\d{2})(\d{2})(\d{4})\.pdf$")

def parse_filename(fichier):
    m = PATTERN.match(str(fichier))
    if not m:
        return pd.NA, pd.NA
    return m.group(1), f"{m.group(4)}-{m.group(3)}-{m.group(2)}"

def load_positifs():
    """Union v6 + v8, dédoublonnage par `fichier`, v8 prioritaire en cas de collision."""
    v6 = pd.read_csv(POSITIFS_V6)
    v8 = pd.read_csv(POSITIFS_V8)
    v6 = v6[v6["niveau"].notna() & v6["error"].isna()].copy()
    v8 = v8[v8["niveau"].notna() & v8["error"].isna()].copy()
    print(f"[info] scores_positifs.csv     : {len(v6)} lignes valides")
    print(f"[info] scores_positifs_v8.csv  : {len(v8)} lignes valides")

    common = set(v6["fichier"]) & set(v8["fichier"])
    if common:
        diverge = []
        for f in common:
            r6 = v6[v6["fichier"] == f].iloc[0]
            r8 = v8[v8["fichier"] == f].iloc[0]
            if r6["score"] != r8["score"] or r6["niveau"] != r8["niveau"]:
                diverge.append((f, r6["score"], r6["niveau"], r8["score"], r8["niveau"]))
        print(f"[info] Collisions fichier   : {len(common)} (v8 prioritaire)")
        if diverge:
            print(f"[warn] Divergences score/niveau sur {len(diverge)} cas :")
            for f, s6, n6, s8, n8 in diverge[:10]:
                print(f"        {f}: v6=score{s6}/{n6} -> v8=score{s8}/{n8}")
            if len(diverge) > 10:
                print(f"        ... {len(diverge) - 10} autres")
        else:
            print(f"[info] Aucune divergence score/niveau sur les collisions")
        v6 = v6[~v6["fichier"].isin(common)]

    pos = pd.concat([v6, v8], ignore_index=True)
    parsed = pos["fichier"].apply(parse_filename)
    pos["siren"]   = parsed.apply(lambda x: x[0])
    pos["cloture"] = parsed.apply(lambda x: x[1])
    pos["label"]   = 1
    print(f"[info] Positifs union dédupliqués : {len(pos)} ({pos['siren'].nunique()} SIREN)")
    return pos

def load_saines():
    df = pd.read_csv(SAINES)
    df = df[df["niveau"].notna() & df["error"].isna()].copy()
    parsed = df["fichier"].apply(parse_filename)
    df["siren"]   = parsed.apply(lambda x: x[0])
    df["cloture"] = parsed.apply(lambda x: x[1])
    df["label"]   = 0
    print(f"[info] Saines : {len(df)} ({df['siren'].nunique()} SIREN)")
    return df

def add_ratios(df):
    tp = df["total_produits"].replace(0, pd.NA)
    tb = df["total_bilan"].replace(0, pd.NA)
    df["ratio_rentabilite"]  = df["resultat_exploitation"] / tp
    df["ratio_solidite"]     = df["fonds_propres"] / tb
    df["ratio_liquidite"]    = df["tresorerie"] / tp
    df["ratio_resultat_net"] = df["resultat_net"] / tp
    return df

def load_meta():
    bodacc = pd.read_csv(BODACC_META, dtype={"siren": str})
    bodacc_meta = bodacc[["siren", "tranche_effectif", "activite_principale", "categorie", "departement"]].copy()
    saines = pd.concat(
        [pd.read_csv(SAINES_META, dtype={"siren": str}),
         pd.read_csv(SAINES_META_400, dtype={"siren": str})],
        ignore_index=True
    )
    saines_meta = saines[["siren", "tranche_effectif", "activite_principale", "categorie", "departement"]].copy()
    return pd.concat([bodacc_meta, saines_meta], ignore_index=True).drop_duplicates("siren")

def load_jugements():
    """Date du jugement la plus ancienne par SIREN (premier jugement = défaillance initiale)."""
    bodacc = pd.read_csv(BODACC_META, dtype={"siren": str})
    bodacc["date_jugement"] = pd.to_datetime(bodacc["date_jugement"], errors="coerce")
    n_total = len(bodacc)
    n_dated = bodacc["date_jugement"].notna().sum()
    grouped = bodacc.dropna(subset=["date_jugement"]).groupby("siren", as_index=False)["date_jugement"].min()
    grouped = grouped.rename(columns={"date_jugement": "date_jugement_min"})
    print(f"[info] BODACC: {n_total} lignes, {n_dated} avec date_jugement, {len(grouped)} SIREN distincts datés")
    return grouped

def main():
    pos = load_positifs()
    sai = load_saines()
    df = pd.concat([pos, sai], ignore_index=True)
    df = add_ratios(df)

    meta = load_meta()
    df = df.merge(meta, on="siren", how="left")

    jug = load_jugements()
    df = df.merge(jug, on="siren", how="left")

    df["cloture_dt"] = pd.to_datetime(df["cloture"], errors="coerce")
    age_days = (df["date_jugement_min"] - df["cloture_dt"]).dt.days
    df["age_avant_jugement"] = age_days / 365.25
    df.loc[df["label"] == 0, "age_avant_jugement"] = np.nan
    df.loc[df["label"] == 0, "date_jugement_min"] = pd.NaT

    n_pos = (df["label"] == 1).sum()
    n_pos_with_age = ((df["label"] == 1) & df["age_avant_jugement"].notna()).sum()
    n_pos_neg_age = ((df["label"] == 1) & (df["age_avant_jugement"] < 0)).sum()
    print(f"\n[info] Positifs avec age_avant_jugement calculé : {n_pos_with_age}/{n_pos}")
    print(f"[info] Positifs avec age_avant_jugement < 0      : {n_pos_neg_age} (cloture après jugement, conservés tels quels)")
    if n_pos_with_age > 0:
        ages = df.loc[(df["label"] == 1) & df["age_avant_jugement"].notna(), "age_avant_jugement"]
        print(f"[info] age_avant_jugement positifs : min={ages.min():.2f} ans  med={ages.median():.2f}  max={ages.max():.2f}  moy={ages.mean():.2f}")
        n_le_3 = (ages <= 3).sum()
        n_gt_3 = (ages > 3).sum()
        print(f"[info]   age <= 3 ans : {n_le_3} ({100*n_le_3/n_pos_with_age:.0f}%)")
        print(f"[info]   age >  3 ans : {n_gt_3} ({100*n_gt_3/n_pos_with_age:.0f}%)")

    df["ape_section"] = df["activite_principale"].astype(str).str[:2]

    tranche_to_etp = {
        "00": 0, "01": 1.5, "02": 4, "03": 7.5,
        "11": 14, "12": 34, "21": 74, "22": 149,
        "31": 224, "32": 374, "41": 749, "42": 1499,
        "51": 3499, "52": 7499, "53": 15000
    }
    df["effectif_estime"] = df["tranche_effectif"].astype(str).map(tranche_to_etp)

    features_num = [
        "total_produits", "resultat_exploitation", "resultat_net",
        "fonds_propres", "tresorerie", "total_bilan", "subv_pct",
        "ratio_rentabilite", "ratio_solidite", "ratio_liquidite", "ratio_resultat_net",
        "cac_certifie", "effectif_estime", "age_avant_jugement"
    ]
    features_cat = ["ape_section", "departement"]

    keep = ["fichier", "siren", "cloture", "nom"] + features_num + features_cat + ["label"]
    df = df[keep]

    df["cac_certifie"] = df["cac_certifie"].map({"true": 1, "True": 1, True: 1,
                                                   "false": 0, "False": 0, False: 0})

    print(f"\n[info] Dataset final : {len(df)} lignes")
    print(f"  - Défaillantes : {(df['label']==1).sum()}")
    print(f"  - Saines       : {(df['label']==0).sum()}")
    print(f"\n[info] Couverture des features :")
    for col in ["effectif_estime", "ape_section", "departement", "age_avant_jugement"]:
        n_all = df[col].notna().sum()
        n_pos = ((df["label"] == 1) & df[col].notna()).sum()
        n_neg = ((df["label"] == 0) & df[col].notna()).sum()
        print(f"    {col:22s} : {n_all}/{len(df)} ({100*n_all/len(df):.0f}%)  [pos {n_pos} / neg {n_neg}]")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(OUT, index=False)
    print(f"\n[done] -> {OUT}")

if __name__ == "__main__":
    main()
