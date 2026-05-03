"""
Construit un dataset unifié défaillantes + saines avec métadonnées INSEE.
SIREN et date de clôture depuis le nom de fichier (fiable).
"""

import pandas as pd
import re
from pathlib import Path

ROOT = Path(__file__).parent.parent
POSITIFS  = ROOT / "data" / "scores_positifs.csv"
SAINES    = ROOT / "data" / "scores_saines.csv"
BODACC_META = ROOT / "bodacc_associations_enrichi.csv"
SAINES_META = ROOT / "data" / "saines_enrichi.csv"
OUT       = ROOT / "ml" / "data" / "dataset.csv"

PATTERN = re.compile(r"^(\d{9})_(\d{2})(\d{2})(\d{4})\.pdf$")

def parse_filename(fichier):
    m = PATTERN.match(fichier)
    if not m:
        return pd.NA, pd.NA
    return m.group(1), f"{m.group(4)}-{m.group(3)}-{m.group(2)}"

def load_and_label(path, label):
    df = pd.read_csv(path)
    df = df[df["niveau"].notna() & df["error"].isna()].copy()
    parsed = df["fichier"].apply(parse_filename)
    df["siren"]   = parsed.apply(lambda x: x[0])
    df["cloture"] = parsed.apply(lambda x: x[1])
    df["label"]   = label
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
    """Métadonnées INSEE pour défaillantes ET saines, au même format."""
    bodacc = pd.read_csv(BODACC_META, dtype={"siren": str})
    bodacc_meta = bodacc[["siren", "tranche_effectif", "activite_principale", "categorie", "departement"]].copy()

    saines = pd.read_csv(SAINES_META, dtype={"siren": str})
    saines_meta = saines[["siren", "tranche_effectif", "activite_principale", "categorie", "departement"]].copy()

    return pd.concat([bodacc_meta, saines_meta], ignore_index=True).drop_duplicates("siren")

def main():
    pos = load_and_label(POSITIFS, label=1)
    sai = load_and_label(SAINES, label=0)
    print(f"[info] Défaillantes scorées : {len(pos)}")
    print(f"[info] Saines scorées       : {len(sai)}")

    df = pd.concat([pos, sai], ignore_index=True)
    df = add_ratios(df)

    # Jointure avec les métadonnées INSEE
    meta = load_meta()
    df = df.merge(meta, on="siren", how="left")

    # Section APE = 2 premiers chiffres du code (regroupe les codes proches)
    df["ape_section"] = df["activite_principale"].astype(str).str[:2]

    # Tranche d'effectif numérique (codes INSEE 00, 01, 02, 03, 11, 12, 21, 22, 31, 32, 41, 42, 51, 52, 53)
    # On convertit en niveau d'effectif moyen approximatif
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
        "cac_certifie", "effectif_estime"
    ]
    features_cat = ["ape_section", "departement"]

    keep = ["fichier", "siren", "cloture", "nom"] + features_num + features_cat + ["label"]
    df = df[keep]

    df["cac_certifie"] = df["cac_certifie"].map({"true": 1, "True": 1, True: 1,
                                                   "false": 0, "False": 0, False: 0})

    print(f"\n[info] Dataset final : {len(df)} lignes")
    print(f"  - Défaillantes : {(df['label']==1).sum()}")
    print(f"  - Saines       : {(df['label']==0).sum()}")
    print(f"\n[info] Couverture des nouvelles features :")
    for col in ["effectif_estime", "ape_section", "departement"]:
        n = df[col].notna().sum()
        print(f"    {col:20s} : {n}/{len(df)} ({100*n/len(df):.0f}%)")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(OUT, index=False)
    print(f"\n[done] -> {OUT}")

if __name__ == "__main__":
    main()
