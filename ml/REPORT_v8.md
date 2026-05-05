# Rapport v8 — Élargissement du sample BODACC

**Date** : 2026-05-05
**Étape** : 1/3 du plan d'élargissement (étapes 2 et 3 — re-train ML, re-calibration — à faire dans une session ultérieure).

## TL;DR

- 323 SIREN BODACC sélectionnés en sample stratifié (vs 64 dans `scores_positifs.csv` actuel) ; 43 ont effectivement des PDFs JOAFE indexés (taux 13.3 %).
- 276 PDFs téléchargés et scorés via Sonnet 4.5, **0 erreur d'extraction**.
- **Coût Sonnet 4.5 : $27.68** (sous le plafond $35 sans déclencher l'arrêt prématuré). Coût moyen $0.10/PDF.
- Wall-clock total : **1 h 52 min** (fetch JOAFE 30 min + extraction 82 min).
- Tous les outputs en `*_v8.*`, **aucun fichier existant modifié**.

## Sample sélectionné

`scripts/select_bodacc_sample.rb` lit `bodacc_associations_enrichi.csv` (1754 SIREN distincts), exclut ceux qui ont déjà au moins un PDF dans `tmp/jo_pdfs/`, `data/pdfs_positifs/` ou `data/pdfs_saines/` (1238 SIREN exclus), puis stratifie avec `srand(42)` :

| Année jugement | Sample v8 |
|---|---|
| 2015 | 1 |
| 2019 | 2 |
| 2020 | 2 |
| 2021 | 1 |
| 2022 | 28 |
| 2023 | 80 (sample) |
| 2024 | 80 (sample) |
| 2025 | 80 (sample) |
| 2026 | 49 |
| **Total** | **323** |

Output : `data/bodacc_sample_v8.csv` (siren, date_jugement, nature_jugement, famille_jugement).

## Fetch JOAFE

`scripts/fetch_jo_for_bodacc.rb` lance `rake scrape_jo:run Q={SIREN}` pour chaque SIREN, identifie par snapshot diff les PDFs nouvellement écrits dans `tmp/jo_pdfs/` et les copie vers `data/pdfs_positifs_v8/`. La rake n'a pas été modifiée (output dir hardcodé respecté).

| Métrique | Valeur |
|---|---|
| SIREN tentés | 323 |
| SIREN avec ≥ 1 PDF | **43 (13.3 %)** |
| PDFs téléchargés | 276 |
| Moyenne PDFs/SIREN | 6.4 |
| Erreurs rake | 0 |
| Durée | 30.0 min |

**Le taux 13 % est plus bas que l'estimation préalable (30–60 %).** Hypothèse : la majorité des associations en procédure collective ont arrêté de déposer leurs comptes annuels au JOAFE plusieurs années avant la défaillance ; elles ne sont donc plus indexées dans le dataset OpenDataSoft `jo_associations`. Pour les 43 SIREN qui *ont* des PDFs, on récupère en revanche un historique riche (en moyenne 6 exercices, allant de 2006 à 2024).

Resume marker : `data/fetch_jo_v8_done.csv` (323 lignes, statuts `ok` / `no_pdf` / `rake_error`).

## Extraction + scoring

`scripts/extract_v8.rb` (lancé via `rails runner`) appelle Sonnet 4.5 avec `ExtractionService::PROMPT` sur chaque PDF, score via `ScoringService` (style `phase4_run.rb` : `OpenStruct` + `cac_certifie?`). Mesure de coût en temps réel via `response.usage`, plafond $35 strict.

| Métrique | Valeur |
|---|---|
| PDFs traités | 276 |
| Extractions OK | 276 |
| Erreurs | 0 |
| Coût total Sonnet 4.5 | **$27.68** |
| Coût moyen / PDF | $0.10 |
| Tokens input moyens | ~52 k / PDF |
| Tokens output moyens | ~290 / PDF |
| Durée | 81.8 min |
| Plafond atteint ? | Non |

Output : `data/scores_positifs_v8.csv` au schéma identique à `scores_positifs.csv`.

## Distribution v8 vs sample existant

### Niveaux Vigil'Asso

| Niveau | v8 (276 PDFs) | scores_positifs.csv (111 PDFs) |
|---|---|---|
| A | 8 (2.9 %) | 2 (1.8 %) |
| B | 64 (23.2 %) | 13 (11.7 %) |
| C | 119 (43.1 %) | 42 (37.8 %) |
| D | 69 (25.0 %) | 44 (39.6 %) |
| E | 16 (5.8 %) | 10 (9.0 %) |
| **Score moyen** | **47.7 / 100** | ≈ 41 / 100 |

**Le sample v8 est sensiblement moins « fragile » que `scores_positifs.csv`** : 26 % A/B contre 14 %, 31 % D/E contre 49 %. Explication la plus probable : le fetch JOAFE remonte tous les exercices indexés par SIREN (de 2006 à 2024), pas seulement ceux proches de la défaillance ; on capture la trajectoire complète de l'asso, dont des années où elle était encore saine. C'est un **biais à corriger côté ML** si on veut entraîner sur un signal « défaillance imminente » :
- Filtrer par âge du compte avant date du jugement (par exemple ≤ 3 ans).
- Ou bien garder cette richesse temporelle et incorporer `age_avant_jugement` comme feature.

### Distribution exercices clôturés (PDFs)

| Période | PDFs |
|---|---|
| 2006–2010 | 75 (27 %) |
| 2011–2015 | 91 (33 %) |
| 2016–2020 | 79 (29 %) |
| 2021–2024 | 23 (8 %) |

Décroissance forte sur la période récente — confirme l'hypothèse « les asso en procédure collective ont arrêté de déposer ».

### Distribution SIREN par année de jugement (43 SIREN avec PDF)

| Année | SIREN |
|---|---|
| 2020 | 1 |
| 2022 | 6 |
| 2023 | 9 |
| 2024 | 11 |
| 2025 | 12 |
| 2026 | 4 |

Le pic 2024–2025 est cohérent avec la composition du sample v8 (160 SIREN sur 323 viennent de ces deux années).

### Top 10 secteurs APE (43 SIREN distincts, sections 2 chiffres)

| APE | Libellé approximatif | SIREN |
|---|---|---|
| 94 | Activités des organisations associatives | 10 |
| 88 | Action sociale sans hébergement | 9 |
| 85 | Enseignement | 7 |
| 93 | Activités sportives, récréatives, loisirs | 3 |
| 78 | Activités liées à l'emploi | 2 |
| 72 | Recherche-développement scientifique | 2 |
| 59 | Production audiovisuelle | 2 |
| 86 | Activités pour la santé humaine | 2 |
| 82 | Activités de soutien aux entreprises | 1 |
| 73 | Publicité, études de marché | 1 |

Concentration attendue sur les secteurs typiques des asso loi 1901 (94, 88, 85, 93 = 67 % des SIREN).

## Cumul vs existant

| Source | PDFs scorés | SIREN distincts |
|---|---|---|
| `scores_positifs.csv` (avant v8) | 111 | 64 |
| `scores_positifs_v8.csv` (nouveau) | 276 | 43 |
| **Cumul si on les union** | **387** | **107** |

L'union des deux samples remonte à 107 SIREN distincts, sous l'objectif initial de "~200 SIREN scorés" mais avec **3.5× plus de PDFs** que le sample précédent (387 vs 111). Pour le ML, le signal utile dépendra du choix de filtrage par âge du compte.

## Fichiers produits

| Chemin | Lignes | Taille |
|---|---|---|
| `scripts/select_bodacc_sample.rb` | 100 | 3 KB |
| `scripts/fetch_jo_for_bodacc.rb` | 110 | 4 KB |
| `scripts/extract_v8.rb` | 200 | 7 KB |
| `data/bodacc_sample_v8.csv` | 324 | 18 KB |
| `data/fetch_jo_v8_done.csv` | 324 | 13 KB |
| `data/pdfs_positifs_v8/` | 276 PDFs | ~80 MB |
| `data/scores_positifs_v8.csv` | 277 | ~50 KB |
| Logs | `/tmp/fetch_jo_v8.log`, `/tmp/extract_v8.log` | |

**Aucune modification** de `bodacc_associations_enrichi.csv`, `scores_positifs.csv`, `dataset.csv`, `ScoringService` ni de la rake `scrape_jo:run`. L'isolation v8 promise est respectée.

## À faire dans la prochaine session (étapes 2 et 3)

Hors scope ici, mais recommandations qui découlent de ce sample :

1. **Étape 2 (re-train ML)** :
   - Décider du filtrage par âge du compte avant `date_jugement` (option proposée : ≤ 3 ans pour ne garder que le signal « pré-défaillance »).
   - Refaire `prepare_dataset.py` en intégrant `scores_positifs_v8.csv` ; vérifier la couverture des features INSEE (`tranche_effectif`, `activite_principale`) qui sont déjà dans `bodacc_associations_enrichi.csv` pour les SIREN v8.
   - Re-tourner `train_final.py` et `train_with_sector_ratios.py`. Comparer aux métriques v6.

2. **Étape 3 (re-calibration)** :
   - Sur le sample combiné CRC + BODACC élargi, refaire le sweep `calibrate_thresholds.rb`.
   - Vérifier si la recommandation v6 (« ne pas adopter ») évolue avec un sample BODACC plus volumineux et plus propre.

## Notes méthodologiques

- **Reproductibilité** : `srand(42)` dans `select_bodacc_sample.rb`, schéma de sortie verrouillé. Les trois scripts ont une resume logic donc on peut relancer sans tout refaire.
- **Coût Sonnet 4.5** : $0.10/PDF en moyenne, soit la moitié de mon estimation initiale ($0.16). Cause : tokens input plus bas que prévus (~52 k au lieu des ~80 k que j'anticipais sur des PDFs moyens). Le plafond $35 n'a pas été touché.
- **Pas de PDF rejeté** par l'API : Sonnet 4.5 a digéré les 276 PDFs, y compris les plus anciens (2006). Le `cac_certifie` a été extrait correctement dans la majorité des cas (à valider sur un échantillon manuel si on veut être strict pour le scoring de gouvernance).
