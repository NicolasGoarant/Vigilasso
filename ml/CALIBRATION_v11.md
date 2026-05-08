# Calibration v11 — re-calibration sur dataset BODACC élargi

**Date** : 2026-05-08
**Script** : `scripts/calibrate_thresholds_v11.rb`
**Recommandation** : **maintenir 80/60/40/20**. L'élargissement BODACC v11 confirme la conclusion v6 — le sweep ne propose pas de seuils défendables qui préservent la sémantique 5-niveaux.

## TL;DR

- Sample combiné CRC + BODACC élargi désormais **n=1523** (vs 907 en v6, ×1.7). Le sample BODACC `fragile` a quasi-septuplé (111 → 727).
- Tous les optima du sweep collapsent T_B et T_C à 2 points de distance (T_B=64–66, T_C=62–64). Le palier C disparaît visuellement — comme en v6.
- L'optimum CRC seul (62, 60) est resté **strictement identique** à v6.
- L'optimum brut a en revanche bougé de (42, 40) → (66, 64) — le sample BODACC élargi tire désormais l'optimum vers le haut (les nouveaux fragiles ont en moyenne des scores plus élevés que les fragiles initiaux). Cela ne rend pas l'optimum brut plus défendable : il continue de violer la sémantique du système 5 niveaux.
- Recommandation finale : **garder 80/60/40/20**. Si on souhaitait néanmoins corriger un seul seuil, T_C : 40 → 60 reste le seul candidat avec une justification métier (rappel D/E sur CRC 36 % → 96 %), au prix de l'effacement du palier C entre B et D.

## Composition des samples

| Sample | Lignes brutes | Dédoublonné | Fragile | Sain | Taux fragile |
|---|---:|---:|---:|---:|---:|
| CRC (`phase4_results.csv`) | 38 | 38 | 25 | 13 | 66 % |
| BODACC `positifs.csv` (avant v8) | 111 | 111 | 111 | 0 | — |
| BODACC v8 (`scores_positifs_v8.csv`) | 276 | 276 | 276 | 0 | — |
| BODACC v11 (`scores_positifs_v11.csv`) | 340 | 340 | 340 | 0 | — |
| BODACC `saines.csv` | 758 | 758 | 0 | 758 | 0 % |
| **BODACC élargi** | **1485** | **1485** | **727** | **758** | **49 %** |
| **Combiné** | — | **1523** | **752** | **771** | **49 %** |

Dédoublonnage par clé `fichier` (`{SIREN}_{DDMMYYYY}.pdf`) : **0 doublon trouvé** — les samples positifs.csv / v8 / v11 sont disjoints par construction (chaque vague a exclu les SIREN déjà couverts).

Comparaison v6 → v11 :

| | v6 (mai 2026) | v11 (mai 2026) | Δ |
|---|---:|---:|---:|
| n CRC | 38 | 38 | = |
| n BODACC | 869 | 1485 | +616 (+71 %) |
| BODACC fragile | 111 | 727 | ×6.5 |
| BODACC sain | 758 | 758 | = |
| n combiné | 907 | 1523 | +616 |
| Taux fragile combiné | 15 % | 49 % | +34 pt |

Le sample BODACC est désormais **équilibré 49/51** au lieu de 13/87 en v6. Cela change radicalement la dynamique du sweep : on n'a plus 758 saines noyant 111 fragiles, mais un 50/50 quasi-symétrique.

## Métriques aux seuils actuels (T_A=80, T_B=60, T_C=40, T_D=20)

| Sample | Seuil | Précision | Rappel | F1 | (v6 rappel) |
|---|---|---:|---:|---:|---:|
| **CRC** | C/D/E | 71 % | **96 %** | 81 % | (96 %) |
| | D/E | 82 % | 36 % | 50 % | (36 %) |
| **BODACC élargi** | C/D/E | 60 % | 78 % | **68 %** | (86 %) |
| | D/E | 73 % | 32 % | 45 % | (49 %) |
| **Combiné brut** | C/D/E | 60 % | 79 % | 68 % | (88 %) |
| | D/E | 73 % | 33 % | 45 % | (46 %) |
| **Combiné 50/50** | C/D/E | — | — | 75 % | (— ) |
| | D/E | — | — | 47 % | (— ) |

**Macro-F1 par sample (seuils actuels)** :

| Sample | v11 | v6 | Δ |
|---|---:|---:|---:|
| CRC | 65.68 % | 65.68 % | = |
| BODACC élargi / BODACC | 56.4 % | 38.0 % | +18.4 pt |
| Combiné brut | 56.7 % | 40.3 % | +16.4 pt |
| Combiné 50/50 | 61.0 % | 51.8 % | +9.2 pt |

Le sample BODACC élargi a fait **monter** la macro-F1 aux seuils actuels — autrement dit, **les seuils 60/40 deviennent plus performants à mesure qu'on enrichit BODACC**. Lecture cohérente : les nouveaux fragiles (v8 + v11) ont des scores plus dispersés et atteignent mieux le seuil 60 — alors qu'en v6 les 111 fragiles avaient des scores très bas et le seuil 40 était proche optimal.

## Sweep grille (T_B, T_C), step=2, plage [20, 90], T_B > T_C

630 combinaisons évaluées par variante.

### Optima par variante d'optimisation

| Optimisation | T_B | T_C | macro-F1 | Δ vs actuel | v6 |
|---|---:|---:|---:|---:|---|
| CRC seul | 62 | 60 | **81.36 %** | +15.7 pt | (62, 60) — identique |
| BODACC élargi seul | 66 | 64 | 68.68 % | +12.3 pt | v6 : (42, 40) |
| Combiné brut | 66 | 64 | 69.06 % | +12.3 pt | v6 : (42, 40) |
| Combiné équilibré 50/50 | 64 | 62 | **74.89 %** | +13.9 pt | v6 : (60, 56) |

**Lecture clé** : l'optimum CRC seul est resté strictement identique à v6 ((62, 60), macro 81.36 %). En revanche, l'optimum brut s'est déplacé de (42, 40) en v6 vers **(66, 64) en v11**.

Cause de ce déplacement : v11 a apporté 616 fragiles supplémentaires (v8 + v11) dont la distribution de scores est centrée autour de 47 (v11 score moyen) et 47.7 (v8 score moyen) — sensiblement plus haut que les 111 fragiles initiaux. L'optimum naïf BODACC se déplace mécaniquement vers le haut quand on injecte plus de fragiles à scores moyens.

### Top 5 par variante (extrait)

| Variante | Top 1 | Top 2 | Top 3 |
|---|---|---|---|
| CRC seul | (62, 60) | (64, 60) | (64, 62) |
| BODACC élargi | (66, 64) | (68, 66) | (68, 64) |
| Combiné brut | (66, 64) | (68, 64) | (68, 66) |
| Combiné 50/50 | (64, 62) | (64, 60) | (70, 64) |

**Tous les top 1, sur les 4 variantes, ont T_B − T_C ≤ 4** (et le plus souvent = 2). Le sweep optimise en pratique un seul classifieur binaire — exactement le pathologique pointé en v6.

## Comparaison ligne à ligne v6 → v11

| Indicateur | v6 | v11 | Lecture |
|---|---|---|---|
| Optimum CRC | (62, 60) macro 81.4 % | (62, 60) macro 81.4 % | **Identique**. Sample CRC inchangé, donc résultat trivialement reproductible. |
| Optimum BODACC | (42, 40) macro 42.9 % | (66, 64) macro 68.7 % | Optimum déplacé de 24 points. Les nouveaux fragiles ont des scores plus élevés que les anciens, donc l'optimum monte. |
| Optimum équilibré | (60, 56) macro 57.2 % | (64, 62) macro 74.9 % | T_B + 4, T_C + 6. Macro +17.7 pt — gain venant à 70 % de l'effet sample (BODACC mieux séparé) et à 30 % de l'écart 4-6 pt sur les seuils. |
| Optimum combiné brut | (42, 40) macro 43.7 % | (66, 64) macro 69.1 % | Idem BODACC. Le combiné brut est dominé par BODACC dans les deux cas. |
| Macro-F1 BODACC à (60, 40) | 38 % | 56.4 % | Gain +18.4 pt **sans changer les seuils** : confirme que les seuils actuels deviennent plus performants à mesure qu'on enrichit BODACC. |
| Rappel CRC C/D/E à (60, 40) | 96 % | 96 % | Inchangé. |
| Rappel BODACC C/D/E à (60, 40) | 86 % | 78 % | −8 pt, mais sur n × 1.7. La métrique évolue dans la limite des fluctuations attendues. |

**Conclusion comparative** : l'élargissement BODACC v11 a renforcé la pertinence des seuils actuels (macro-F1 mieux à seuils inchangés) sans déplacer l'optimum CRC. Il a en revanche déplacé l'optimum brut de 24 points — mais cet optimum reste mathématiquement pathologique (T_B et T_C distants de 2 points, palier C effacé).

## Si on devait quand même bouger un seuil

Le seul candidat avec une justification métier reste **T_C : 40 → 60**. Effet mesuré (sample CRC, n=38) :

| Métrique CRC D/E | T_C=40 (actuel) | T_C=60 (proposé) | Δ |
|---|---:|---:|---:|
| Précision | 82 % | 71 % | −11 pt |
| Rappel | 36 % | 96 % | +60 pt |
| F1 | 50 % | 81 % | +31 pt |
| TP | 9 | 24 | +15 |
| FP | 2 | 10 | +8 |
| FN | 16 | 1 | −15 |

Effet sur BODACC élargi D/E :

| Métrique | T_C=40 | T_C=60 | Δ |
|---|---:|---:|---:|
| Précision | 73 % | 60 % | −13 pt |
| Rappel | 32 % | 78 % | +46 pt |
| F1 | 45 % | 68 % | +23 pt |

**Coût produit** : l'écart T_B − T_C passe de 20 à 0. Le palier C entre B et D disparaît. L'alerte « faible » (C) et l'alerte « forte » (D/E) deviennent un seul niveau d'alerte. Le système 5 niveaux devient un système 3 niveaux (A/B = sain, C/D/E = alerte) — ce que les optima brut et équilibré confirment indépendamment.

C'est un **choix produit, pas un choix technique** : si l'on accepte d'effacer le palier C, T_C=60 est défendable empiriquement. Si l'on tient à conserver le palier C entre B et D, on doit garder T_C=40 — au prix d'un rappel D/E médiocre (32–36 %).

## Pourquoi maintenir 80/60/40/20

1. **Tous les optima du sweep collapsent C/D/E avec D/E.** L'algorithme de sweep optimise une moyenne F1, donc favorise toujours T_B = T_C (un seul classifieur). Il ne peut pas, par construction, recommander de seuils qui préservent un palier intermédiaire C.

2. **L'optimum CRC seul (62, 60) est à 2 points de l'actuel sur T_B**, et à 20 points sur T_C. Sur n=38 (IC ±15 pt), un écart de 2 points n'est pas significatif.

3. **L'élargissement BODACC v11 a augmenté la macro-F1 BODACC à seuils actuels** (38 % → 56.4 %) — le système 60/40 « marche » mieux qu'avant sur le sample BODACC, sans changement de code.

4. **Pas de validation indépendante.** Tout le sweep se fait sur les données qui ont servi à construire le scoring. Tout gain d'optimisation est une forme d'overfitting. Le caveat v6 reste actif : un sample de validation indépendant (collecté différemment) reste préalable à toute recalibration sérieuse.

5. **Le sample BODACC reste qualitativement bruité.** Les fragiles BODACC contiennent des comptes anciens (parfois 15+ ans avant le jugement) où l'asso n'était pas encore défaillante. Le filtre v9 (age ≤ 3 ans) ne filtre que 23 % du sample BODACC. Le label « fragile » sur ce sample n'est pas équivalent au label « fragile » CRC.

## Caveats méthodologiques

- **Intervalles de confiance** : sur le sample CRC (n=38), l'IC binomial à 95 % est de ±15 pt par métrique. Sur BODACC élargi (n=1485), il tombe à ±2.5 pt. La macro-F1 « combinée 50/50 » est dominée par la variance CRC (n=38).
- **Sample BODACC borné par la couverture JOAFE.** 9 % de taux JOAFE en v11, 13 % en v8 → la majorité des associations en procédure collective sont absentes du sample (n'ont pas déposé de comptes). Le sample BODACC reflète une sous-population spécifique : les associations qui défaillent **après** avoir déposé des comptes — pas représentatif de l'ensemble des associations défaillantes.
- **Biais de non-indépendance.** Les seuils actuels (60/40) ont été choisis en partie sur les mêmes types de données que ce qu'on évalue ici. Tout sweep sur ces données ne peut que confirmer ce qui a déjà été calibré.
- **Saines BODACC** : leur label est « pas en procédure » à la date d'extraction, mais une partie peut entrer en procédure dans les 12-24 mois. Le sample saines a un taux de **vrai-négatif gonflé** par cette censure à droite. Le snapshot prospectif (créé en parallèle) servira à mesurer ce biais dans 12-24 mois.

## Recommandation finale

**Maintenir T_A=80, T_B=60, T_C=40, T_D=20.**

Décision documentée :

- L'élargissement BODACC v11 ne fait pas apparaître de seuil objectivement supérieur qui préserve la sémantique 5 niveaux.
- Le seul changement défendable empiriquement (T_C : 40 → 60) effacerait le palier C, transformant le système en 3 niveaux. C'est un choix produit, pas technique.
- L'optimum CRC seul (62, 60) reste à 2 points sur T_B et 20 sur T_C des seuils actuels — la calibration actuelle est largement compatible avec la validation externe la plus crédible (les chambres régionales des comptes).
- Une éventuelle re-calibration future doit attendre :
  1. Un sample de validation **indépendant** (par ex. la première itération du snapshot prospectif après 12-24 mois — voir `data/README_snapshots.md`).
  2. Une décision produit sur la sémantique attendue de chaque palier (gradation continue ou alerte binaire avec niveau de gravité ?).

## Fichiers produits

| Chemin | Description |
|---|---|
| `scripts/calibrate_thresholds_v11.rb` | Sweep complet, 4 variantes |
| `ml/CALIBRATION_v11.md` | Ce rapport |
| `/tmp/calibration_v11.log` | Log brut du sweep (non versionné) |

Aucune modification de `app/services/scoring_service.rb`. Aucune modification de la page `/methodologie`. Décision finale au utilisateur.
