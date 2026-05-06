# Rapport v9 — Re-train ML sur sample BODACC élargi (étape 2a)

**Date** : 2026-05-06
**Étape** : 2a/3 du plan d'élargissement (suite de v8). Étape 2b « nouvelle feature comptable » et étape 3 « re-calibration des seuils » non couvertes ici.
**Périmètre** : régénérer le dataset ML avec les positifs v8 inclus, mesurer l'effet d'`age_avant_jugement` comme feature, comparer trois variantes.

## TL;DR

- **Élargir le sample (v6 → v9, +275 lignes, positifs équilibrés 106 → 125 après filtrage age)** apporte un gain réel sur les pipelines comptables purs : AUC test FINANCIER 0.732 → 0.832, AUC test FIN+EFFECTIF+APE 0.803 → 0.850.
- **Inclure `age_avant_jugement` comme feature est inutilisable** : la feature étant structurellement NaN pour 100 % des saines, le RF (sklearn 1.6 gère NaN nativement) la transforme en proxy quasi-parfait du label. AUC test = 1.000 sur 5 des 6 pipelines de v9-with-age, importance #1 à 57 % (vs ~10 % pour le top suivant). C'est du leakage, pas un signal exploitable.
- **Recommandation : adopter v9-filtered** (positifs filtrés à age ≤ 3 ans avant jugement, feature `age_avant_jugement` retirée). Gain modéré mais cohérent en AUC ; le filtrage préserve l'honnêteté du sample (un compte 2008 n'est pas représentatif d'une asso pré-défaillance).
- Caveat : test set n=50, intervalle de confiance ±10 points sur AUC. Le gain v6 → v9-filtered (≈+0.05 AUC sur les pipelines complexes) est tangent à la limite de significativité.

## Méthode

### Régénération du dataset

`ml/prepare_dataset_v9.py` (nouveau, ne touche pas `prepare_dataset.py`) produit `ml/data/dataset_v9.csv` :

1. Union de `data/scores_positifs.csv` (111 lignes valides) et `data/scores_positifs_v8.csv` (276 lignes valides). Dédoublonnage par `fichier`, v8 prioritaire en cas de collision. **0 collision détectée** dans les faits (les SIREN v8 ont été choisis pour ne pas chevaucher les PDFs déjà disponibles).
2. Jointure avec `bodacc_associations_enrichi.csv` sur `siren`, en prenant `min(date_jugement)` par SIREN (premier jugement = date de défaillance initiale). 1746 SIREN BODACC datés disponibles.
3. Calcul `age_avant_jugement = (date_jugement - cloture) / 365.25` pour les positifs uniquement. Saines → NaN structurel.
4. Colonnes existantes (effectif, APE, département, ratios) inchangées.

Stats du dataset_v9 :

| | Lignes | SIREN distincts |
|---|---|---|
| Positifs (v6 + v8) | 387 | 107 |
| Saines | 758 | 264 |
| **Total** | **1145** | **371** |

Distribution `age_avant_jugement` sur les 382 positifs avec date de jugement (5 SIREN sans date trouvée dans le BODACC enrichi) :

| Stat | Valeur |
|---|---|
| min | -0.82 ans (2 cas où la clôture est postérieure au jugement, conservés) |
| médiane | 6.49 ans |
| max | 19.14 ans |
| moyenne | 7.27 ans |
| age ≤ 3 ans | 132 (35 %) |
| age > 3 ans | 250 (65 %) |

**Lecture** : la majorité des PDFs positifs viennent de plusieurs années avant la défaillance. C'est la conséquence directe du fetch JOAFE par SIREN dans v8 — il remonte tous les exercices indexés, pas seulement les plus récents. D'où l'intérêt du filtrage age ≤ 3 ans pour la variante v9-filtered.

### Trois variantes comparées

| Variante | Dataset | Positifs | Feature `age_avant_jugement` |
|---|---|---|---|
| **v6 baseline** | dataset.csv (870 lignes) | 106 (équilibré) | absente |
| **v9-with-age** | dataset_v9.csv (1145 lignes) | 290 (équilibré) | présente (NaN pour saines) |
| **v9-filtered** | dataset_v9.csv, drop positifs age>3 | 125 (équilibré) | retirée |

### Cinq pipelines comparés

Hyperparamètres identiques pour les 15 cellules : RF 300 arbres, max_depth=6, random_state=42, split 80/20 stratifié.

1. **FINANCIER** : 6 ratios comptables (ratio_rentabilite, _solidite, _liquidite, _resultat_net, subv_pct, cac_certifie).
2. **+EFFECTIF** : ajoute `effectif_estime` (estimation tranche INSEE → ETP).
3. **+APE** : ajoute one-hot des sections APE (2 chiffres).
4. **+RATIOS RELATIFS** : ratios bruts + effectif + écart à la médiane sectorielle pour chaque ratio.
5. **FULL** : pipeline 4 + APE one-hot.

Les pipelines 1–3 viennent de `train_final*.py`, les pipelines 4–5 de `train_with_sector_ratios*.py`.

## Table de comparaison

### v6 (baseline, dataset.csv)

| Pipeline | AUC CV | AUC test | Précision | Rappel | F1 |
|---|---|---|---|---|---|
| FINANCIER       | 0.798 ± 0.016 | 0.732 | 67 % | 67 % | 0.67 |
| +EFFECTIF       | 0.804 ± 0.015 | 0.753 | 64 % | 67 % | 0.65 |
| +APE            | 0.833 ± 0.020 | 0.803 | 71 % | 71 % | 0.71 |
| +RATIOS RELATIFS | 0.824 ± 0.047 | 0.779 | 68 % | 85 % | 0.76 |
| FULL            | 0.837 ± 0.024 | 0.805 | 68 % | 85 % | 0.76 |

### v9-with-age (dataset_v9.csv, age comme feature, NaN pour saines)

| Pipeline | AUC CV | AUC test | Précision | Rappel | F1 |
|---|---|---|---|---|---|
| FINANCIER       | 0.787 ± 0.046 | 0.820 | 71 %  | 84 %  | 0.77 |
| +EFFECTIF       | **1.000** ± 0.000 | **1.000** | 100 % | 100 % | 1.00 |
| +APE            | **1.000** ± 0.000 | **1.000** | 100 % | 100 % | 1.00 |
| +RATIOS RELATIFS | **1.000** ± 0.000 | **1.000** | 100 % | 100 % | 1.00 |
| FULL            | **1.000** ± 0.000 | **1.000** | 98 %  | 100 % | 0.99 |

(`FINANCIER` ne contient pas `age_avant_jugement`, d'où l'AUC réaliste. Toutes les autres pipelines incluent age et présentent du leakage.)

### v9-filtered (dataset_v9.csv, drop positifs age>3, feature age retirée)

| Pipeline | AUC CV | AUC test | Précision | Rappel | F1 |
|---|---|---|---|---|---|
| FINANCIER       | 0.816 ± 0.039 | 0.832 | 74 % | 68 % | 0.71 |
| +EFFECTIF       | 0.824 ± 0.026 | 0.814 | 81 % | 68 % | 0.74 |
| +APE            | 0.839 ± 0.026 | 0.850 | 85 % | 68 % | 0.76 |
| +RATIOS RELATIFS | 0.842 ± 0.049 | 0.798 | 72 % | 75 % | 0.73 |
| FULL            | 0.848 ± 0.052 | 0.807 | 76 % | 79 % | 0.78 |

### Synthèse v6 vs v9-filtered (le seul comparatif honnête)

| Pipeline | AUC test v6 | AUC test v9-filtered | Δ AUC | F1 v6 | F1 v9-filtered | Δ F1 |
|---|---|---|---|---|---|---|
| FINANCIER       | 0.732 | 0.832 | **+0.100** | 0.67 | 0.71 | +0.04 |
| +EFFECTIF       | 0.753 | 0.814 | +0.061 | 0.65 | 0.74 | +0.09 |
| +APE            | 0.803 | 0.850 | +0.047 | 0.71 | 0.76 | +0.05 |
| +RATIOS RELATIFS | 0.779 | 0.798 | +0.019 | 0.76 | 0.73 | -0.03 |
| FULL            | 0.805 | 0.807 | +0.002 | 0.76 | 0.78 | +0.02 |

Le gain est concentré sur les pipelines comptables purs (FINANCIER, +EFFECTIF, +APE). Sur les pipelines à ratios relatifs, l'effet est neutre (FULL stagne à 0.805 → 0.807).

## Importance de `age_avant_jugement` (variante v9-with-age)

Top 10 feature importances du modèle FIN+EFFECTIF+APE en variante v9-with-age :

```
 1. age_avant_jugement             0.5701   <-- 57 % à elle seule
 2. ratio_liquidite                0.0990
 3. effectif_estime                0.0705
 4. ratio_resultat_net             0.0596
 5. ratio_solidite                 0.0580
 6. ratio_rentabilite              0.0524
 7. subv_pct                       0.0226
 8. ape_93                         0.0112
 9. ape_94                         0.0077
10. ape_84                         0.0077
```

Pour comparaison, top 10 du même pipeline en v9-filtered (sans la feature age) :

```
 1. ratio_liquidite                0.2236
 2. ratio_solidite                 0.1850
 3. ratio_resultat_net             0.1620
 4. ratio_rentabilite              0.1318
 5. effectif_estime                0.0907
 6. subv_pct                       0.0666
 7. ape_88                         0.0182
 8. ape_84                         0.0150
 9. ape_94                         0.0150
10. cac_certifie                   0.0146
```

`age_avant_jugement` est rang **1/39** avec une importance de **0.57** — soit ~5× la 2ᵉ feature. Aucune feature comptable n'a ce profil dans v9-filtered (top à 0.22 pour ratio_liquidite, distribution beaucoup plus plate). C'est la signature d'un **proxy quasi-parfait du label** : les saines ont toutes la valeur NaN, ce qui suffit au RF pour les séparer parfaitement des positifs (qui ont des valeurs numériques).

## Décision recommandée

**Adopter v9-filtered. Rejeter v9-with-age. Garder v6 comme baseline historique mais ne plus l'utiliser comme référence en production.**

### Pourquoi v9-with-age est inutilisable

`age_avant_jugement` est par construction non-définie pour les négatifs (une asso saine n'a pas de jugement). N'importe quelle stratégie d'imputation (NaN natif, médiane des positifs, sentinel) marquera tous les négatifs avec une valeur uniforme distincte de la distribution des positifs. Le RF capture cette uniformité comme signal et obtient AUC=1.000 — résultat trompeur. Cette feature ne peut pas être utilisée telle quelle en production : à l'inférence, on n'a pas non plus la date du jugement (sinon l'asso n'est plus à scorer), donc la feature serait NaN pour 100 % des cas réels et sortirait toujours du côté "saine".

### Pourquoi v9-filtered plutôt que v6

Trois arguments :

1. **Gain mesurable en AUC** sur les pipelines comptables purs (+0.05 à +0.10 sur le test set). Pas révolutionnaire mais cohérent à travers FINANCIER, +EFFECTIF, +APE.
2. **Échantillon positif plus représentatif** : 125 PDFs avec age ≤ 3 ans = comptes effectivement « pré-défaillance », vs un mélange v6 + v8 brut où 65 % des positifs viennent de 4 à 19 ans avant le jugement (ces comptes-là ne signalent rien d'imminent).
3. **Précision en hausse, rappel stable à légèrement bas** sur FIN+EFF+APE (71 % → 85 % précision, 71 % → 68 % rappel). Pour Vigil'Asso, dont la cible UX est un score-radar et pas un classifieur binaire automatique, le coût d'un faux positif est plus élevé que celui d'un faux négatif marginal — privilégier la précision est cohérent avec le produit.

### Caveats à mentionner systématiquement

- **n=50 sur le test set** de v9-filtered. σ approximatif sur AUC ≈ 0.07. Le gain v6 → v9-filtered (+0.05 sur FIN+EFF+APE) est à la limite de significativité ; pris isolément il pourrait être du bruit. C'est la cohérence entre les pipelines (gain positif sur 4/5) qui rend le résultat crédible, pas une cellule individuelle.
- **Le filtrage age ≤ 3 ans est un choix méthodologique, pas dérivé des données.** Tester 1 an et 5 ans avant de figer le seuil reste à faire (pas dans le scope de cette étape 2a).
- **Le sample positif reste borné par le fetch JOAFE** : 43 SIREN distincts dans v8 sur 323 tentés (13 %). Une majorité d'assos en procédure collective ne déposent plus leurs comptes au JOAFE, donc le sample est biaisé vers celles qui continuaient à déposer. Limite structurelle non corrigible sans changer de source.
- **La calibration des seuils du `ScoringService` (étape 3) n'a pas été refaite ici.** Elle pourrait modifier la recommandation v6 « ne pas adopter » des seuils alternatifs. À traiter dans une session ultérieure avec `scripts/calibrate_thresholds.rb` sur le sample v9-filtered.

## Ce qui n'a pas changé

Aucune écriture sur :
- `ml/data/dataset.csv` (intact)
- `data/scores_positifs.csv`, `data/scores_positifs_v8.csv`
- `bodacc_associations_enrichi.csv`
- `ScoringService` (`app/services/scoring_service.rb`)
- `app/views/pages/methodologie.html.erb`
- `ml/prepare_dataset.py`, `ml/train_final.py`, `ml/train_with_sector_ratios.py`

Fichiers créés :
- `ml/prepare_dataset_v9.py`
- `ml/data/dataset_v9.csv`
- `ml/train_final_v9.py`
- `ml/train_with_sector_ratios_v9.py`
- `ml/REPORT_v9.md`

Logs des 6 runs disponibles dans `/tmp/v9_runs/` (v6, v9-with-age, v9-filtered × {final, sector_ratios}).

## À faire ensuite

1. **Étape 2b** (nouvelle feature comptable) — non traitée ici. Candidats à explorer si on veut pousser plus loin : ratio frais de personnel / charges, dynamique inter-exercices (pertes consécutives), durée moyenne d'amortissement.
2. **Étape 3** (re-calibration `ScoringService`) — refaire `calibrate_thresholds.rb` sur le sample v9-filtered + CRC, vérifier si la recommandation v6 « ne pas adopter de nouveaux seuils » tient.
3. **Mise à jour `/methodologie`** une fois la calibration tranchée — pas avant.
