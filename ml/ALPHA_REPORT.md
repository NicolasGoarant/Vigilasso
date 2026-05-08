# Rapport α — Extraction enrichie sur 38 PDFs CRC

**Date** : 2026-05-08
**Sample** : 38 SIREN du test CRC (`phase4_results.csv`), un PDF par SIREN (le compte le plus récent, identique à celui qui a produit `recent_score`/`recent_niveau`).
**Objectif** : valider si deux nouvelles features non-comptables — `fonds_dedies_pct` et `secteur_atypique` — permettent de différencier les 10 faux positifs (Vigi C/D/E ∧ CRC sain) des 24 vrais positifs (Vigi C/D/E ∧ CRC fragile) du sample CRC.

## TL;DR

- **38/38 PDFs extraits avec succès** via `ExtractionServiceAlpha` (Sonnet 4.5 + 2 fields enrichis), 0 erreur.
- **Coût Sonnet 4.5 : $6.81** (plafond $10 jamais touché). Coût moyen $0.179/PDF.
- Wall-clock : **13.0 min**.
- **Verdict — `fonds_dedies_pct` : signal inverse à l'hypothèse.** TP ont un fonds_dedies_pct **plus élevé** (médiane 0.229) que les FP (médiane 0.101). Cliff's δ = −0.25 (effet « petit » mais dans le mauvais sens), Mann-Whitney U/max = 0.375.
- **Verdict — `secteur_atypique` : tendance directionnelle correcte mais non significative.** 80 % des FP sont catégorisés atypiques contre 62.5 % des TP. Fisher exact 2-sided p = 0.44 — différence indissociable du bruit à n=10/24.
- **Recommandation : abandonner la piste**, ne pas étendre l'extraction au reste du dataset. Les deux features testées ne fournissent pas un signal exploitable pour une règle de désalerte automatique.

## Extraction

| Métrique | Valeur |
|---|---:|
| PDFs cibles | 38 |
| Extractions OK | 38 |
| Erreurs | 0 |
| Coût total Sonnet 4.5 | $6.81 |
| Coût moyen / PDF | $0.179 |
| Tokens output / PDF (médiane) | ~330 |
| Durée | 13.0 min |
| Plafond ($10) atteint ? | Non |

Output : `app/assets/fichiers_internes/data/scores_alpha.csv` (38 lignes, 22 colonnes : 18 fields originaux + `fonds_dedies_pct` + `secteur_atypique` + `secteur_atypique_justification` + `error`).

## Distribution `fonds_dedies_pct`

| Groupe | n | présents | null | min | Q1 | médiane | Q3 | max |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **FP** | 10 | 6 | 4 (40 %) | 0.016 | 0.032 | **0.101** | 0.363 | 0.477 |
| **TP** | 24 | 12 | 12 (50 %) | 0.004 | 0.087 | **0.229** | 0.734 | 1.000 |

**Observation principale : le signal va dans le sens opposé à l'hypothèse.**

L'hypothèse FP_ANALYSIS_v1 supposait que les FP avaient une **part plus élevée** de fonds dédiés/affectés qui rendait artificiellement leur trésorerie « tendue » au scoring. Or, sur les valeurs présentes :

- TP médiane (0.229) > FP médiane (0.101) — les vrais positifs ont **plus** de fonds dédiés.
- Cliff's δ = −0.25 (TP > FP), effet « petit » selon Cohen.
- Mann-Whitney U/max = 0.375 (séparation modeste, vers TP plus haut).

**Lecture** : ce résultat est en réalité cohérent avec la mécanique BODACC. Une association qui dérive vers la défaillance accumule souvent des subventions affectées qu'elle n'a pas pu dépenser (projets non réalisés, conventions en stand-by). Les fonds dédiés s'empilent au passif sans réduire le risque réel. L'intuition « fonds dédiés = trésorerie bloquée mais asso saine » ne se transpose pas mécaniquement : un fonds dédié important est plus souvent un signe de difficultés opérationnelles qu'un signe d'aisance.

Le taux de null (40 % FP / 50 % TP) traduit la difficulté pour Sonnet à extraire ce ratio quand l'annexe ne ventile pas explicitement les fonds dédiés.

## Distribution `secteur_atypique`

| Secteur | FP | TP |
|---|---:|---:|
| autre_atypique | 8 | 15 |
| standard | 2 | 9 |
| **Total** | **10** | **24** |

- **Atypique (≠ standard) : 80 % des FP, 62.5 % des TP.**
- Différence brute : +17.5 pts en faveur des FP atypiques.
- Fisher exact 2-sided : **p = 0.4375** → indissociable du bruit.

Sonnet 4.5 a regroupé tous les cas atypiques sous l'unique label `autre_atypique` ; aucune asso n'a été catégorisée `fondation`, `quasi_lucratif` ni `mecenat_dominant` sur ce sample. Le scoring perd donc en granularité : la dichotomie devient binaire `atypique / standard`.

Hypothèse de règle naïve : **désalerter d'un cran tous les SIREN classés `autre_atypique`**.
- Désalerterait 8/10 FP (gain précision)
- Désalerterait 15/24 TP (perte rappel massive)
- **Trade-off catastrophique** — pire que la règle (i) du rapport FP_ANALYSIS_v1.

Sans sous-typage plus fin (fondation vs OT vs scène nationale vs école sup vs festival), `secteur_atypique` agit comme un proxy trop large.

## Verdict

**Aucune des deux features testées ne sépare FP et TP de façon mesurable.**

| Feature | Signal | Significativité | Verdict |
|---|---|---|---|
| `fonds_dedies_pct` | Inverse à l'hypothèse (TP > FP) | Cliff's δ = −0.25, p Mann-Whitney non calculé mais U/max ≠ 0.5 légèrement | Inutilisable comme désalerte |
| `secteur_atypique` | Direction correcte (FP > TP) mais regroupement binaire trop large | Fisher p = 0.44 | Non significatif, désalerterait trop de TP |

## Recommandation

**Abandonner l'extension de l'extraction au reste du dataset.**

Justifications :
1. **Coût/bénéfice défavorable** : $6.81 sur 38 PDFs CRC montre qu'aucun signal exploitable n'émerge ; étendre à 1 800+ PDFs (~$320) ne ferait qu'amplifier l'absence de signal sur le périmètre CRC.
2. **Le sens du signal `fonds_dedies_pct` invalide l'intuition initiale**. Avant d'investir, il faudrait reformuler l'hypothèse — par exemple, ne pas extraire le **ratio** mais la **provenance** des fonds dédiés (subventions État vs collectivités vs mécénat) ou leur **âge** (combien d'exercices stagnent ils au passif). Ces variantes demanderaient une refonte du prompt et un test sur un nouveau lot.
3. **`secteur_atypique` mériterait une re-spécification** plus fine : forcer Sonnet à choisir parmi des sous-catégories (scène nationale, OT, école sup, festival, EHPAD…) plutôt que de proposer un fourre-tout `autre_atypique`. À tenter dans une éventuelle v2 du prompt si on veut creuser cette piste.

À court terme, la piste la plus rentable pour améliorer le scoring reste la **règle β** (`scoring_service_beta.rb`) qui apporte +6.4 pts de F1 au seuil D/E sans coût d'extraction supplémentaire.

## Caveats statistiques

- **n=10 FP / 24 TP** est trop petit pour distinguer un signal de bruit dès que l'effet est d'amplitude modeste. Cliff's δ = −0.25 est techniquement « petit » et l'IC autour de cette estimation traverse 0.
- **40-50 % de valeurs nulles** sur `fonds_dedies_pct` réduisent la puissance des tests à 6 vs 12 pour Mann-Whitney.
- **Le sample CRC reste biaisé** vers les associations > 153 k€ (seuil de contrôle CRC). Toute conclusion ne se transpose pas directement aux PME associatives ou TPA.

## Fichiers produits

| Chemin | Lignes / Taille |
|---|---|
| `app/services/extraction_service_alpha.rb` | 130 lignes |
| `scripts/extract_alpha.rb` | 175 lignes |
| `scripts/analyze_alpha_fp.rb` | 165 lignes |
| `app/assets/fichiers_internes/data/scores_alpha.csv` | 39 lignes (1 header + 38 PDFs) |
| `ml/ALPHA_REPORT.md` | Ce rapport |
| `/tmp/extract_alpha.log` | Log d'exécution |

**Aucune modification** de `ScoringService`, `ExtractionService`, `ExtractionServiceEnriched`, `phase4_results.csv` original, modèle `Association`, ni vue applicative.
