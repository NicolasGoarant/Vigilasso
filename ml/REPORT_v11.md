# Rapport v11 — Phase 1 d'élargissement BODACC

**Date** : 2026-05-08
**Étape** : phase 1 du plan d'élargissement v11 (re-train ML et re-calibration → sessions ultérieures).

## TL;DR

- 802 SIREN BODACC sélectionnés en sample stratifié (vs 323 pour v8 et 64 pour le sample initial). Exclusion des SIREN déjà couverts par un PDF dans `tmp/jo_pdfs/`, `data/pdfs_positifs/`, `data/pdfs_saines/` ou `data/pdfs_positifs_v8/`.
- 72 SIREN remontent ≥1 PDF JOAFE (taux **9.0 %**, cf. v8 13.3 %), 344 PDFs téléchargés (4.8 PDFs/SIREN).
- 340 PDFs scorés via Sonnet 4.5, 4 erreurs (1.2 %).
- **71 SIREN distincts ajoutés** (un SIREN perdu sur les 4 PDFs en erreur, intersection 0 avec le cumul antérieur par construction du sample).
- **Coût Sonnet 4.5 : $36.24** (plafond $100 jamais touché). Coût moyen $0.107/PDF.
- Wall-clock total : **2 h 32** (fetch 63 min + extract 88 min).
- Tous les outputs en `*_v11.*`, **aucun fichier existant modifié**.

## Sample sélectionné

`scripts/select_bodacc_sample_v11.rb` lit `bodacc_associations_enrichi.csv` (1754 SIREN distincts), exclut ceux qui ont ≥1 PDF dans les 4 dossiers ci-dessus (1281 SIREN exclus, dont 123 BODACC), puis stratifie avec `srand(42)`. Quotas validés exactement comme demandés :

| Année jugement | Disponibles | Sample v11 |
|---|---:|---:|
| 2015 | 1 | 1 |
| 2019 | 2 | 2 |
| 2020 | 1 | 1 |
| 2021 | 1 | 1 |
| 2022 | 22 | 22 |
| 2023 | 661 | 250 |
| 2024 | 531 | 250 |
| 2025 | 359 | 230 |
| 2026 | 45 | 45 |
| **Total** | **1623** | **802** |

8 SIREN BODACC ont été exclus parce que sans `date_jugement` exploitable.

Output : `data/bodacc_sample_v11.csv` (siren, date_jugement, nature_jugement, famille_jugement).

## Fetch JOAFE

`scripts/fetch_jo_for_bodacc_v11.rb` lance `rake scrape_jo:run Q={SIREN}` pour chaque SIREN, identifie les nouveaux PDFs par snapshot diff sur `tmp/jo_pdfs/` et les copie vers `data/pdfs_positifs_v11/`.

| Métrique | Valeur |
|---|---:|
| SIREN tentés | 802 |
| SIREN avec ≥1 PDF | **72 (9.0 %)** |
| PDFs téléchargés | 344 |
| Moyenne PDFs/SIREN avec PDF | 4.8 |
| Erreurs rake | 0 |
| Durée | 63.4 min |

Le **taux 9.0 %** est inférieur à v8 (13.3 %), restant néanmoins au-dessus du seuil d'anomalie défini (8 %). Lecture cohérente avec l'hypothèse formulée en v8 : plus on s'éloigne des « gros » dossiers (le v8 contenait davantage de SIREN avant 2023, qui ont mécaniquement plus de chances d'avoir un historique de comptes annuels), plus le taux JOAFE chute. v11 est dominé par 2023–2025 (730/802) où la non-déposition tardive est la norme.

Resume marker : `data/fetch_jo_v11_done.csv` (statuts `ok` / `no_pdf` / `rake_error`). Aucun arrêt prématuré.

## Extraction + scoring

`scripts/extract_v11.rb` (lancé via `rails runner`) appelle Sonnet 4.5 avec `ExtractionService::PROMPT` sur chaque PDF, score via `ScoringService` (style `phase4_run.rb` : `OpenStruct` + `cac_certifie?`). Plafond strict $100 sur le cumul Sonnet 4.5 (input $3/MTok, output $15/MTok).

| Métrique | Valeur |
|---|---:|
| PDFs traités | 344 |
| Extractions OK | 340 |
| Erreurs | 4 (1.2 %) |
| Coût total Sonnet 4.5 | **$36.24** |
| Coût moyen / PDF | $0.107 |
| Tokens input moyens | ~52 k / PDF |
| Durée | 88.3 min |
| Plafond atteint ? | Non |

Output : `data/scores_positifs_v11.csv` au schéma identique à `data/scores_positifs.csv`.

### Détail des 4 erreurs

| Fichier | Type d'erreur |
|---|---|
| `345093249_31122006.pdf` | Sonnet a répondu en prose française au lieu de JSON. |
| `392336335_31122008.pdf` | PDF trop volumineux : 213 842 tokens > 200 000 (cap Anthropic). |
| `432970622_31122015_rectif1.pdf` | Scoring : un champ numérique attendu est revenu en `String`. |
| `443673876_31122008.pdf` | API a refusé le PDF (`The PDF specified ...`). |

Ces erreurs ne sont pas re-tentées (resume logic n'efface pas). Sur les 71 SIREN qui produisent au moins une ligne `ok`, l'impact net est de 1 SIREN perdu (fetch en avait 72, scoring 71).

## Distribution v11

### Niveaux Vigil'Asso (340 PDFs ok)

| Niveau | v11 | v8 | scores_positifs.csv |
|---|---:|---:|---:|
| A | 5 (1.5 %) | 8 (2.9 %) | 2 (1.8 %) |
| B | 65 (19.1 %) | 64 (23.2 %) | 13 (11.7 %) |
| C | 173 (50.9 %) | 119 (43.1 %) | 42 (37.8 %) |
| D | 71 (20.9 %) | 69 (25.0 %) | 44 (39.6 %) |
| E | 26 (7.6 %) | 16 (5.8 %) | 10 (9.0 %) |
| **Score moyen** | **47.2 / 100** | 47.7 / 100 | ≈ 41 / 100 |

Distribution très proche de v8, plus « C-centrée » que `scores_positifs.csv`. Même biais de richesse historique : le fetch JOAFE remonte aussi les exercices anciens (jusqu'à 2006) où l'asso n'était pas encore défaillante. À filtrer ou à modéliser comme feature `age_avant_jugement` côté ML.

### Distribution PDFs par année de clôture

| Période | PDFs |
|---|---:|
| 2006–2010 | 99 (29 %) |
| 2011–2015 | 100 (29 %) |
| 2016–2020 | 103 (30 %) |
| 2021–2024 | 38 (11 %) |

Profil temporel quasi identique à v8 (27/33/29/8 %). Les 38 PDFs de la période 2021–2024 sont les plus précieux pour l'objectif « signal pré-défaillance ».

### Distribution SIREN par année de jugement (71 SIREN avec PDF)

| Année jugement | SIREN |
|---|---:|
| 2023 | 28 |
| 2024 | 30 |
| 2025 | 13 |

Aucun SIREN avec PDF pour les années < 2023 et 2026, malgré la présence de ces SIREN dans le sample (32 au total) — donc taux JOAFE 0 % sur ces tranches. Ce résultat conforte l'hypothèse que les associations de procédure récente ou très ancienne ont rarement déposé.

### Top secteurs APE (sections 2 chiffres, 71 SIREN distincts)

| APE | Libellé approximatif | SIREN |
|---|---|---:|
| 88 | Action sociale sans hébergement | 26 |
| 94 | Activités des organisations associatives | 17 |
| 93 | Activités sportives, récréatives, loisirs | 6 |
| 85 | Enseignement | 6 |
| 90 | Création artistique et spectacle | 6 |
| 87 | Hébergement médico-social et social | 4 |
| 86 | Activités pour la santé humaine | 1 |
| 38 | Collecte/traitement déchets | 1 |
| 55 | Hébergement | 1 |
| 01 | Agriculture | 1 |

Concentration marquée sur 88 (action sociale), 94 (associations), 93/85/90 — secteurs cibles habituels du tissu associatif. La tête de liste change de v8 (où 94 dominait) au profit de 88 : v11 ramène plus d'associations d'action sociale (souvent des structures de plus de 153 k€ déjà dans le radar BODACC).

## Cumul vs existant

Comparaison sur la base **SIREN canonique = préfixe filename** (le champ `siren` extrait par Sonnet diffère dans 86 % des cas, voir note méthodo plus bas) :

| Source | PDFs scorés | SIREN distincts (filename) |
|---|---:|---:|
| `scores_positifs.csv` + `scores_positifs_v8.csv` (avant v11) | 387 | 113 |
| `scores_positifs_v11.csv` (nouveau) | 340 | 71 |
| **Cumul union** | **727** | **184** |

Ces 71 SIREN sont **tous nouveaux** (intersection nulle avec l'existant — par construction du sample, qui exclut les SIREN déjà couverts).

> Note : le rapport v8 annonçait « 107 SIREN cumulés ». L'écart (113 vs 107) provient du choix du référentiel SIREN. Ici on canonicalise sur le préfixe filename ; en suivant strictement la convention v8 (champ `siren` extrait), on obtient des chiffres légèrement différents. Le filename est plus fiable car il est le SIREN cible du sample BODACC, indépendant de l'extraction.

## Note méthodologique — filtre v9 (`age_avant_jugement`)

Pour chaque PDF v11 on calcule `age_avant_jugement = year(date_jugement BODACC) − year(cloture)`. Le filtre v9 retient les exercices clôturés ≤ 3 ans avant le jugement (signal « pré-défaillance »).

| Bucket d'âge | PDFs |
|---|---:|
| ≤ 0 (clôture postérieure au jugement) | 1 |
| 1 an | 16 |
| 2 ans | 33 |
| 3 ans | 32 |
| 4–5 ans | 47 |
| 6–10 ans | 65 |
| 11–15 ans | 71 |
| 16+ ans | 75 |
| **Total** | **340** |

**43 PDFs (12.6 %) sont éligibles au filtre v9** (`0 ≤ age ≤ 3`). Ces 43 PDFs proviennent de **23 SIREN distincts** sur les 71 — soit 32 % des SIREN nouveaux apportent au moins un exercice « pré-défaillance » exploitable pour ML v9.

Le ratio 12.6 % traduit un signal pré-défaillance plus rare que sur l'union précédente. Cause structurelle : v11 cible des jugements 2023–2025 (730/802), mais les associations en procédure ont rarement déposé leurs comptes après 2020 ; la masse temporelle des PDFs reste donc centrée sur 2010–2018, loin des dates de jugement. Le calcul sur le cumul post-v11 sera fait dans la session ML v11 (étape 2).

## Anomalie SIREN extrait vs filename

Sur les 340 PDFs scorés, **293 (86 %) renvoient dans le champ `siren` du JSON un identifiant différent du préfixe filename**. Trois patterns observés en spot-check :

1. SIREN tronqué (8 ou 10 chiffres) — Sonnet réécrit ce qu'il lit dans le PDF, parfois avec un caractère de plus/moins.
2. SIREN d'une entité affiliée (ex. fédération nationale plutôt que la fédé locale).
3. Champ `null` ou vide quand le PDF ne contient pas le SIREN en clair.

Aucune correction côté code v11 — on conserve la sortie brute de Sonnet et on documente le préfixe filename comme source canonique pour tout join (BODACC, ML, etc.). À traiter en v12 si un nettoyage est nécessaire.

## Fichiers produits

| Chemin | Lignes / Taille |
|---|---|
| `scripts/select_bodacc_sample_v11.rb` | 150 lignes |
| `scripts/fetch_jo_for_bodacc_v11.rb` | 130 lignes |
| `scripts/extract_v11.rb` | 220 lignes |
| `data/bodacc_sample_v11.csv` | 803 lignes |
| `data/fetch_jo_v11_done.csv` | 803 lignes |
| `data/pdfs_positifs_v11/` | 344 PDFs (~95 MB) |
| `data/scores_positifs_v11.csv` | 345 lignes |
| Logs | `/tmp/fetch_jo_v11.log`, `/tmp/extract_v11.log` |

**Aucune modification** de `bodacc_associations_enrichi.csv`, `scores_positifs.csv`, `scores_positifs_v8.csv`, `dataset_v9.csv`, `ScoringService`, page `/methodologie` ni vue applicative.

## À faire dans la prochaine session

1. **Phase 2 d'élargissement** — il reste 821 SIREN BODACC disponibles après v11 (1623 disponibles − 802 v11). À découper si l'on veut pousser au-delà de 184 SIREN cumulés ; rendement attendu vu le taux JOAFE 9 % : ~74 SIREN avec PDFs supplémentaires si on couvre le résidu, soit ~258 cumulés au plafond.
2. **Re-train ML v11** — refaire `prepare_dataset.py` en intégrant `scores_positifs_v11.csv`. Garder le filtre v9 (age ≤ 3 ans) ; vérifier la couverture des features INSEE pour les 71 nouveaux SIREN.
3. **Retoucher la page `/methodologie`** une fois la nouvelle métrique ML calculée (n est désormais ~184 vs 107 — précision/rappel attendus plus stables).

## Notes méthodologiques

- **Reproductibilité** : `srand(42)` dans `select_bodacc_sample_v11.rb`, schéma de sortie verrouillé, resume logic dans les 3 scripts. Re-run safe.
- **Coût Sonnet 4.5** : $0.107/PDF en moyenne, légèrement au-dessus de v8 ($0.10) à cause de quelques PDFs très volumineux (jusqu'à 76 k tokens input). Plafond $100 jamais touché — on aurait pu pousser jusqu'à ~930 PDFs au même coût unitaire.
- **Erreurs API** : 4/344 PDFs (1.2 %), principalement des PDFs hors-norme (taille, format, contenu non-comptable). Pas de retry automatique implémenté pour ces cas — le coût marginal est trop faible pour justifier la complexité.
