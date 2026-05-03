"""
Construit un dataset unifié défaillantes + saines.
SIREN et date de clôture sont récupérés depuis le nom de fichier (fiable),
pas depuis l'extraction Claude (souvent vide).
"""

import pandas as pd
import re
from pathlib import Path

ROOT = Path(__file__).parent.parent
POSITIFS = ROOT / "data" / "scores_positifs.csv"
SAINES   = ROOT / "data" / "scores_saines.csv"
OUT      = ROOT / "ml" / "data" / "dataset.csv"

PATTERN = re.compile(r"^(\d{9})_(\d{2})(\d{2})(\d{4})\.pdf$")

def parse_filename(fichier):
    """Extrait SIREN + date de clôture depuis 'SIREN_DDMMYYYY.pdf'."""
    m = PATTERN.match(fichier)
    if not m:
        return pd.NA, pd.NA
    siren = m.group(1)
    cloture = f"{m.group(4)}-{m.group(3)}-{m.group(2)}"  # YYYY-MM-DD
    return siren, cloture

def load_and_label(path, label):
    df = pd.read_csv(path)
    df = df[df["niveau"].notna() & df["error"].isna()].copy()
    # Récupère SIREN + cloture depuis le nom du fichier
    parsed = df["fichier"].apply(parse_filename)
    df["siren_clean"]   = parsed.apply(lambda x: x[0])
    df["cloture_clean"] = parsed.apply(lambda x: x[1])
    df["label"] = label
    return df

def add_ratios(df):
    tp = df["total_produits"].replace(0, pd.NA)
    tb = df["total_bilan"].replace(0, pd.NA)
    df["ratio_rentabilite"]  = df["resultat_exploitation"] / tp
    df["ratio_solidite"]     = df["fonds_propres"] / tb
    df["ratio_liquidite"]    = df["tresorerie"] / tp
    df["ratio_resultat_net"] = df["resultat_net"] / tp
    return df

def main():
    pos = load_and_label(POSITIFS, label=1)
    sai = load_and_label(SAINES, label=0)
    print(f"[info] Défaillantes scorées : {len(pos)}")
    print(f"[info] Saines scorées       : {len(sai)}")

    df = pd.concat([pos, sai], ignore_index=True)
    df = add_ratios(df)

    # On utilise le SIREN/cloture extraits du filename, pas ceux de Claude
    df["siren"]   = df["siren_clean"]
    df["cloture"] = df["cloture_clean"]

    features = [
        "total_produits", "resultat_exploitation", "resultat_net",
        "fonds_propres", "tresorerie", "total_bilan",
        "subv_pct",
        "ratio_rentabilite", "ratio_solidite", "ratio_liquidite", "ratio_resultat_net",
        "cac_certifie",
    ]
    keep = ["fichier", "siren", "cloture", "nom"] + features + ["label"]
    df = df[keep]

    df["cac_certifie"] = df["cac_certifie"].map({"true": 1, "True": 1, True: 1,
                                                   "false": 0, "False": 0, False: 0})

    print(f"\n[info] Dataset final : {len(df)} lignes")
    print(f"  - Défaillantes : {(df['label']==1).sum()}")
    print(f"  - Saines       : {(df['label']==0).sum()}")
    print(f"  - SIREN renseignés : {df['siren'].notna().sum()}")

    print(f"\n[info] Distribution années par asso :")
    counts = df.groupby("siren").size().value_counts().sort_index()
    for n, k in counts.items():
        print(f"    {n} année(s) : {k} assos")

    n_multi = (df.groupby("siren").size() >= 2).sum()
    n_multi_pos = (df[df["label"]==1].groupby("siren").size() >= 2).sum()
    n_multi_sai = (df[df["label"]==0].groupby("siren").size() >= 2).sum()
    print(f"\n[info] Assos avec ≥2 années (variations calculables) : {n_multi}")
    print(f"  - Défaillantes : {n_multi_pos}")
    print(f"  - Saines       : {n_multi_sai}")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(OUT, index=False)
    print(f"\n[done] -> {OUT}")

if __name__ == "__main__":
    main()
