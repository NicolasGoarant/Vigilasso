# Rapport v10 — Étape 2b : features non-comptables

**Date** : 2026-05-06
**Étape** : 2b/3 du plan d'élargissement (étapes 2a v9 et 3 calibration ailleurs).
**Périmètre** : tester 4 features non-comptables candidates sur un sample de 400 PDFs (200 positifs + 200 saines), mesurer l'effet sur les 5 pipelines ML.

## TL;DR

- **Recommandation : rejeter v10.** Les 4 nouvelles features candidates n'apportent pas de signal exploitable au-delà du bruit. Sur 6 pipelines comparés (v9-filtered restreint au même sample que v10 vs v10 avec nouvelles features), 5 cellules sont en baisse (-0.005 à -0.015 AUC test) et 1 en hausse (+0.014). Différences toutes dans le bruit (σ AUC ≈ 0.07 à n=50 test set).
- **Coût Sonnet** : $50.03 (plafond pile atteint, arrêt propre au PDF #380/400). Durée 117 min. Coût moyen $0.13/PDF (vs $0.10 sur v8 — les PDFs récents avec annexes complètes sont plus volumineux en tokens).
- **Sortie informative** : on sait maintenant que les 2 features Sonnet (`cac_certification_qualite`, `concentration_financeurs`) et les 2 dérivées locales (`evolution_subv_3ans`, `evolution_resultat_3ans`) ne valent pas le coût d'extraction et de maintenance pour le pipeline de production.
- 1 feature initialement prévue (`delai_publication_jours`) a été **droppée avant extraction** : la date de parution JOAFE n'est pas extractible depuis les PDFs ni depuis les logs `telechargements_*.csv` (qui contiennent la date de clôture, pas la date de parution).

## Méthode

### Sample (400 PDFs)

`scripts/select_pdfs_v10.rb` lit `ml/data/dataset_v9.csv` et sélectionne :

- **200 positifs** : 132 avec `age_avant_jugement ≤ 3 ans` (toutes les disponibles), complétés par 68 positifs supplémentaires triés par `cloture` desc (les plus récents). Stratégie déclinée du plan utilisateur (« les 200 plus récents si moins de 200 sont éligibles »).
- **200 saines** : tirage aléatoire `Random.new(42)`.

Résolution PDF dans `data/pdfs_positifs/`, `data/pdfs_positifs_v8/`, `data/pdfs_saines/`, `tmp/jo_pdfs/` (premier match). 400/400 résolus.

Output : `data/pdfs_sample_v10.csv` (pdf_path, fichier, siren, cloture, label).

### Extraction (Sonnet 4.5 enrichi)

`app/services/extraction_service_enriched.rb` clone `ExtractionService::PROMPT` et ajoute deux fields au schéma JSON :

- `cac_certification_qualite` : enum string ou null (`certifie_sans_reserve`, `certifie_avec_reserve`, `refus_certification`, `alerte_continuite_exploitation`).
- `concentration_financeurs` : float [0, 1] ou null (% du plus gros financeur public sur le total des subventions, depuis l'annexe nominative quand présente).

`scripts/extract_v10.rb` (rails runner) itère sur le sample, écrit `data/scores_v10.csv` (resume sur `fichier`, sleep 3s, retry expo sur 429, plafond $50 strict).

| Métrique | Valeur |
|---|---|
| PDFs traités | **380/400** (cap atteint pile) |
| Erreurs | 0 |
| Coût total | **$50.03** |
| Durée | 117 min |
| Coût moyen | $0.132/PDF (vs $0.10 sur v8) |
| Tokens input moyens | ~52 k / PDF |
| Tokens output moyens | ~325 / PDF |

Distribution finale du sample extrait : 200 positifs + 180 saines (les 20 saines manquantes sont les 20 derniers items de la liste, jamais atteints — le sample concatène positifs puis saines, donc l'arrêt prématuré ampute les saines).

### Couverture des nouvelles features

Sur les 380 PDFs extraits :

| Feature | Couverture totale | Couverture positifs | Couverture saines | Décision |
|---|---|---|---|---|
| `cac_certification_qualite` | 256/380 (67 %) | 66 % | 69 % | **KEEP** (>30 %) |
| `concentration_financeurs`  | 121/380 (32 %) | 36 % | 28 % | **KEEP** (>30 %) |
| `evolution_subv_3ans`        | 238/380 (63 %) | 62 % | 64 % | **KEEP** |
| `evolution_resultat_3ans`    | 237/380 (62 %) | 61 % | 63 % | **KEEP** |
| ~~`delai_publication_jours`~~ | — | — | — | **DROP avant extraction** (date de parution JOAFE non extractible) |

Distribution `cac_certification_qualite` (256 valeurs non-null) :

| Valeur | n | % parmi non-null |
|---|---|---|
| certifie_sans_reserve            | 232 | 91 % |
| alerte_continuite_exploitation   | 14  | 5 % |
| certifie_avec_reserve            | 7   | 3 % |
| refus_certification              | 3   | 1 % |

**Constat** : 91 % des certifications sont « sans réserve ». L'info utile (alerte continuité, refus, réserve) ne concerne que 24/380 = 6 % du sample, dont seulement une fraction tombera dans le test set après équilibrage. Trop sparse pour porter un signal robuste.

`concentration_financeurs` (121 valeurs) : moyenne 0.52 sur saines vs 0.51 sur positifs, std ≈ 0.22. Pas de différence visible entre les deux populations dans la simple statistique descriptive.

### Comparaison sample-matched

Pour isoler l'effet des features (et pas du sample), la baseline `v9-filtered` est restreinte aux **mêmes 380 fichiers** que v10 (inner join). Après filtre age ≤ 3 ans, on retombe sur 125 positifs + 158 saines = 283 cas, équilibrés à 250 (pipelines `final.py`) ou 238 (pipelines `sector_ratios.py`). Test set n=48–50.

Hyperparamètres : RF 300 arbres, max_depth=6, random_state=42, split 80/20 stratifié.

## Table de comparaison (v9-filtered vs v10, sample-matched)

### Pipelines `train_final_v10.py`

| Pipeline | AUC CV v9 | AUC CV v10 | AUC test v9 | AUC test v10 | F1 v9 | F1 v10 | Δ AUC test |
|---|---|---|---|---|---|---|---|
| FINANCIER  | 0.816 ± 0.047 | 0.822 ± 0.021 | 0.773 | 0.760 | 0.71 | 0.71 | **-0.013** |
| +EFFECTIF  | 0.856 ± 0.037 | 0.845 ± 0.026 | 0.747 | 0.742 | 0.72 | 0.71 | **-0.005** |
| +APE       | 0.856 ± 0.035 | 0.860 ± 0.030 | 0.760 | 0.774 | 0.74 | 0.75 | **+0.014** |

### Pipelines `train_with_sector_ratios_v10.py`

| Pipeline | AUC CV v9 | AUC CV v10 | AUC test v9 | AUC test v10 | F1 v9 | F1 v10 | Δ AUC test |
|---|---|---|---|---|---|---|---|
| BASELINE_RATIOS  | 0.858 ± 0.083 | 0.845 ± 0.072 | 0.767 | 0.752 | 0.72 | 0.72 | **-0.015** |
| +RATIOS_RELATIFS | 0.875 ± 0.061 | 0.865 ± 0.056 | 0.842 | 0.833 | 0.79 | 0.78 | **-0.009** |
| +APE             | 0.866 ± 0.065 | 0.869 ± 0.057 | 0.852 | 0.842 | 0.79 | 0.75 | **-0.010** |

### Lecture

- **Aucune amélioration nette.** Sur 6 pipelines, 5 régressent légèrement et 1 progresse légèrement. Toutes les différences sont DANS le bruit (σ AUC ≈ 0.07 à n=50).
- AUC CV moyenne sur 6 pipelines : v9 = 0.854 / v10 = 0.851 — quasi-identique.
- F1 moyenne : v9 = 0.745 / v10 = 0.737 — légère baisse.
- Le seul gain est sur `final.py + APE` (+0.014 AUC test), qui est aussi celui où le RF a le plus d'espace pour exploiter de la redondance — i.e. le moins fiable comme indicateur d'un vrai signal.

## Importance des nouvelles features dans le RF

### Pipeline `+APE` de `train_final_v10.py`, variante v10 (top 15)

```
 1. ratio_liquidite                     0.1758
 2. ratio_solidite                      0.1681
 3. ratio_rentabilite                   0.1203
 4. ratio_resultat_net                  0.1130
 5. effectif_estime                     0.0963
 6. evolution_resultat_3ans             0.0650   <-- nouvelle
 7. subv_pct                            0.0631
 8. evolution_subv_3ans                 0.0459   <-- nouvelle
 9. concentration_financeurs            0.0443   <-- nouvelle
10. cacq_certifie_sans_reserve          0.0156   <-- nouvelle (one-hot)
11. ape_94                              0.0144
12. cacq_alerte_continuite_exploitation 0.0098   <-- nouvelle (one-hot)
13. ape_88                              0.0093
14. ape_93                              0.0091
15. cac_certifie                        0.0073
```

### Pipeline `+APE` de `train_with_sector_ratios_v10.py`, variante v10 (top 15)

```
 1. rel_ratio_liquidite                 0.1220
 2. ratio_liquidite                     0.1190
 3. rel_ratio_solidite                  0.1098
 4. rel_ratio_rentabilite               0.0926
 5. ratio_solidite                      0.0859
 6. ratio_rentabilite                   0.0728
 7. rel_ratio_resultat_net              0.0593
 8. ratio_resultat_net                  0.0557
 9. effectif_estime                     0.0506
10. rel_subv_pct                        0.0499
11. evolution_resultat_3ans             0.0486   <-- nouvelle
12. subv_pct                            0.0316
13. evolution_subv_3ans                 0.0294   <-- nouvelle
14. concentration_financeurs            0.0264   <-- nouvelle
15. ape_94                              0.0067
```

### Synthèse importances

- `evolution_resultat_3ans` : la plus importante des 4 nouvelles, rang 6 (final) / 11 (sector). Importance 0.05–0.07 — non-négligeable mais pas dominante.
- `evolution_subv_3ans` et `concentration_financeurs` : importance 0.03–0.05. Le RF les utilise mais elles sont redondantes avec les ratios financiers de base.
- `cac_certification_qualite` (4 colonnes one-hot) : importance < 0.02 chacune. Quasi-inutiles. La modalité « alerte_continuite_exploitation » qui aurait pu être un signal fort ne concerne que 14/380 cas, trop rare.

**Le RF utilise les nouvelles features (les importances ne sont pas nulles), mais leur ajout ne fait pas progresser les métriques globales.** C'est la signature classique d'une feature qui apporte du signal *redondant* avec ce qui est déjà capté par les ratios financiers. Quand le RF perd un peu de signal sur une feature primaire (split stratégique légèrement différent à cause du nouvel espace de features), il le récupère sur la nouvelle, et le solde est ~0.

## Décision recommandée

**Rejeter v10. Garder v9-filtered comme référence pour la suite (étape 3 calibration des seuils).**

### Pourquoi

1. **Pas de gain au-delà du bruit** sur 6 pipelines comparés sample-matched. AUC test moyenne v9 = 0.79 / v10 = 0.78. F1 moyenne v9 = 0.74 / v10 = 0.74.
2. **Coût d'usage non-négligeable** : adopter v10 imposerait `claude-sonnet-4-5` avec un prompt enrichi et `max_tokens=1500` au lieu de 1024 (~+5 % output cost, mais surtout maintenance d'un second prompt versionné). Pas justifié pour un gain absent.
3. **Sparsité structurelle** des features les plus prometteuses : `concentration_financeurs` 32 % de couverture, `cac_certification_qualite` dominée à 91 % par « certifie_sans_reserve » (modalité quasi-binaire qui ne fait que dupliquer `cac_certifie`).
4. **Le pipeline existant (v9-filtered) atteint déjà AUC test 0.85 et F1 0.79** sur le pipeline `+APE` de `sector_ratios`. C'est la cible vers laquelle converger pour la calibration de production.

### Ce qu'on apprend (résultat informatif négatif)

- Les annexes nominatives de subventions sont **trop peu présentes** pour qu'un signal de concentration soit utilisable à l'échelle. Sortir cette feature du backlog.
- Le diagnostic CAC binaire (`cac_certifie`) **suffit** : la qualité fine de la certification (réserve, refus, alerte) concerne <6 % du sample. Pas la peine de demander à Sonnet la qualité explicite — gain en signal trop faible pour le coût en tokens output et complexité d'extraction.
- Les **évolutions multi-exercices** (`evolution_*_3ans`) ne battent pas les ratios statiques pour ce sample. Hypothèse : un seul exercice avec ratios dégradés (ratio_resultat_net négatif, ratio_solidite faible) suffit déjà à classer correctement, sans besoin d'analyser la trajectoire.

### Caveats

- **Test set n=48–50.** Sigma AUC ~0.07. Le verdict « pas de gain » est solide, mais une petite amélioration <+0.05 AUC ne pourrait pas être confirmée à cette taille — il aurait fallu re-tester sur un sample plus large pour conclure plus durement. Le coût de cette validation supplémentaire (encore ~$50 + 2h) ne se justifie pas vu les indices déjà recueillis (importances faibles + pas de différence stat-significative).
- **Le sample positifs reste contraint à 132 SIREN avec age ≤ 3 ans.** Les évolutions multi-exercices fonctionnent moins bien sur des historiques courts. Si on étendait à age ≤ 5 ans, on aurait plus de positifs (mais avec plus de bruit de représentativité « pré-défaillance »).

## Ce qui n'a pas changé

Aucune écriture sur :
- `ml/data/dataset.csv`, `ml/data/dataset_v9.csv` (intacts)
- `data/scores_positifs.csv`, `data/scores_positifs_v8.csv`
- `bodacc_associations_enrichi.csv`
- `ScoringService` (`app/services/scoring_service.rb`)
- `app/services/extraction_service.rb` (le service web reste sur le prompt original)
- `app/views/pages/methodologie.html.erb`
- `ml/prepare_dataset.py`, `ml/train_final.py`, `ml/train_with_sector_ratios.py`
- `ml/prepare_dataset_v9.py`, `ml/train_final_v9.py`, `ml/train_with_sector_ratios_v9.py`

Fichiers créés :

| Chemin | Rôle |
|---|---|
| `app/services/extraction_service_enriched.rb` | Prompt Sonnet enrichi (2 fields supplémentaires) |
| `scripts/select_pdfs_v10.rb` | Sélection 400 PDFs (200 pos + 200 neg) |
| `scripts/extract_v10.rb` | Extraction Sonnet 4.5 enrichie, plafond $50 strict |
| `data/pdfs_sample_v10.csv` | 400 PDFs sélectionnés |
| `data/scores_v10.csv` | 380 PDFs extraits (cap $50 atteint au #380) |
| `ml/prepare_dataset_v10.py` | Joint v10 + dataset_v9, calcule évolutions, one-hot CAC |
| `ml/data/dataset_v10.csv` | 380 lignes avec features héritées + 4 nouvelles |
| `ml/train_final_v10.py` | Comparaison v9-filtered vs v10 (3 pipelines) |
| `ml/train_with_sector_ratios_v10.py` | Comparaison v9-filtered vs v10 (3 pipelines sector) |
| `ml/REPORT_v10.md` | Ce rapport |

Logs des runs dans `/tmp/v10_runs/v10_final.{log,json}` et `/tmp/v10_runs/v10_sector.{log,json}`. Log d'extraction dans `/tmp/extract_v10.log`.

## À faire ensuite

L'étape 2b confirme que **les features candidates faciles à extraire ne porteront pas Vigil'Asso plus loin**. Pistes restantes (hors scope de cette session) :

1. **Étape 3 (re-calibration des seuils ScoringService)** sur le sample v9-filtered + CRC. C'est le prochain chantier prioritaire selon le plan d'origine, et indépendant de cette étape 2b.
2. **Tester un pipeline non-RF** (gradient boosting type XGBoost / LightGBM, ou régression logistique régularisée) sur dataset_v9.csv. Les RF max_depth=6 plafonnent peut-être le signal sans qu'on s'en rende compte.
3. **Élargir le sample positifs** : rejouer `select_bodacc_sample.rb` avec un sample 2× plus grand pour viser ~250 SIREN positifs au lieu de 107. C'est principalement une question de coût Sonnet (~$80–100 supplémentaires) et de temps d'extraction (~3–4h).
4. **Features nouvelles plus ambitieuses** (hors scope ici, à explorer si on relance une étape 2c) : variation inter-exercices de `total_produits` (croissance/décroissance d'activité), poids des CDD/CDI dans la masse salariale, ratio créances clients / produits (lead-time encaissement).

Pas de changement à `/methodologie` à ce stade — la page reste sur les métriques v6 pour l'instant ; mise à jour à programmer après l'étape 3.
