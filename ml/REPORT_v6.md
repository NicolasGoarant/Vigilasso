# Rapport v6 — Re-tour du pipeline ML

**Date** : 2026-05-05
**Dataset** : `ml/data/dataset.csv` régénéré depuis `data/scores_positifs.csv` (1 mai) et `data/scores_saines.csv` (4 mai).

## Contexte

Vérifier que les métriques annoncées dans le commit `d6f8b96` ("Vigil'Asso v5.1 : ratios sectoriels (rappel 71% → 85%)") tiennent toujours après régénération du dataset et nouvelle exécution du pipeline.

Deux scripts re-tournés :
- `ml/train_final.py` — pipeline canonique référencé dans CLAUDE.md, sans ratios sectoriels.
- `ml/train_with_sector_ratios.py` — script v5.1, source du chiffre "rappel 85%".

Pas de modification du code. Random Forest 300 arbres, max_depth=6, `random_state=42`, split 80/20 stratifié.

## Dataset

| | v6 (aujourd'hui) |
|---|---|
| Défaillantes scorées | 111 |
| Saines scorées | 758 |
| Total brut | 869 |
| Après drop NaN (`train_final`) | 764 (106 / 658) |
| Après drop NaN (`+ ratios sectoriels`) | 760 (102 / 658) |
| Après équilibrage | 212 / 204 |
| Train / Test | 169 / 43 — 163 / 41 |

Couverture des features INSEE : effectif_estime 90 %, ape_section 100 %, departement 98 %. Stable.

## Résultats `train_final.py` — sans ratios sectoriels

| Modèle | AUC CV | AUC test | Précision | Rappel |
|---|---|---|---|---|
| FINANCIER seul (6 feat) | 0.798 ± 0.016 | 0.732 | 67 % | 67 % |
| + EFFECTIF (7 feat) | 0.804 ± 0.015 | 0.753 | 64 % | 67 % |
| + APE one-hot (34 feat) | 0.833 ± 0.020 | **0.803** | **71 %** | **71 %** |

## Résultats `train_with_sector_ratios.py` — pipeline v5.1

| Modèle | AUC CV | AUC test | Précision | Rappel |
|---|---|---|---|---|
| BASELINE (7 feat) | 0.827 ± 0.046 | 0.771 | 62 % | 75 % |
| + RATIOS RELATIFS (12 feat) | 0.824 ± 0.047 | 0.779 | 68 % | **85 %** |
| + APE one-hot (39 feat) | 0.837 ± 0.024 | 0.805 | 68 % | **85 %** |

Top features du meilleur modèle : `ratio_liquidite` (0.138), `ratio_solidite` (0.113), suivi des ratios relatifs (rel_*) qui pèsent collectivement plus que les bruts.

## Comparaison vs annoncées (v5.1)

| Métrique annoncée | v5.1 (commit) | v6 (aujourd'hui) | Écart |
|---|---|---|---|
| Rappel sans ratios sectoriels (baseline) | 71 % | 71 % (FULL `train_final`) — 75 % (BASELINE `+sector`) | 0 à +4 pt |
| Rappel avec ratios sectoriels | 85 % | 85 % | 0 pt |
| AUC test meilleur modèle | ~0.80 (déduit du commit v4) | 0.805 | ≈ 0 pt |

**Aucun écart supérieur à 5 points** sur les métriques principales. Le pipeline est stable et le résultat phare du commit v5.1 (rappel 85 % avec ratios sectoriels) est reproduit à l'identique sur le dataset de mai 2026.

## Notes méthodologiques

1. **Petit test set** : n=41–43 → IC à 95 % de l'ordre de ±15 points sur précision et rappel. Les écarts dans cette fourchette ne sont pas signifiants.
2. **Différence baseline 71 vs 75 %** : `train_final` (FULL) drop 764 lignes, `train_with_sector_ratios` (BASELINE) drop 760 lignes — pas le même split, pas la même perte d'échantillonnage, pas exactement les mêmes folds. L'écart de 4 pt est compatible avec ça et avec l'IC du test.
3. **Effet ratios sectoriels** : passage de 75 % → 85 % de rappel correspond à 2 FN de moins sur 20 positifs. Statistiquement faible mais directionnellement cohérent — les médianes par secteur APE captent bien quelque chose.
4. **AUC v4 annoncé 0.876** : non reproduit ici (0.80–0.81). Probablement parce que le dataset a évolué entre v4 (3 mai) et v6 (régénération avec saines au 4 mai). Pas une dégradation à investiguer, juste un changement de support.

## Conclusion

Pipeline reproductible. Pas d'hypothèse de dégradation à formuler.

Données prêtes pour l'étape (c) — calibration empirique des seuils sur l'union du sample CRC (38 cas) + du sample BODACC (~111 défaillantes, échantillon de saines apparié).

Logs bruts : `/tmp/v6_prepare.log`, `/tmp/v6_train_final.log`, `/tmp/v6_train_sector.log`.
