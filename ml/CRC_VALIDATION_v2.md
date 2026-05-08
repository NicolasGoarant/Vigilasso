# Validation CRC v2 — élargissement du sample par récupération des SIREN perdus

**Date** : 2026-05-08
**Scripts** : `scripts/identify_lost_sirens.rb`, `scripts/fetch_jo_phase4_v2.rb`, `scripts/phase4_prep_v2.rb`, `scripts/phase4_run_v2.rb`, `scripts/recompute_confusion_v2.rb`
**Recommandation** : **maintenir l'affichage n=38** sur la home et la page méthodologie. L'opération a apporté 0 nouveau cas binaire à la matrice de confusion CRC. Les chiffres 96 % rappel et 71 % précision restent inchangés mais s'enrichissent désormais d'**intervalles de confiance binomiaux Wilson 95 %** : précision C/D/E **[54 %, 83 %]**, rappel C/D/E **[80 %, 99 %]**.

## TL;DR

- **74 SIREN « perdus »** identifiés (sirens_verified.csv − phase4_results.csv − PDFs déjà locaux) et scrapés via `rake scrape_jo:run`.
- **Découverte structurelle** : sur ces 74 SIREN, **seuls 9 ont un label binaire utilisable** (7 fragilite_financiere + 2 rien_critique). Les 65 autres sont des rapports CRC sur d'autres sujets (gouvernance 40, conformité 17, performance 5, etc.) — par construction exclus de la matrice CRC binaire.
- **Sur ces 9 binaires : 0 PDF JOAFE indexé.** Tous sont dans les 28 SIREN sans PDF retournés par le scraping. Le sample binaire CRC reste donc strictement à n=38.
- **46 SIREN ont été scorés** (label non-binaire), pour usage exploratoire uniquement (croisement audit_primary × niveau Vigil'Asso) — ces données sont stockées dans `phase4_results_v2.csv` séparé.
- **Coût Sonnet 4.5 : $10.63** (plafond $15 jamais touché). Wall-clock total 35 min (15 min fetch + 20 min extraction).
- Aucune modification de `phase4_results.csv` original, `ScoringService`, page `/methodologie`, ni de la home.

## Composition des 74 SIREN à scraper

| audit_primary | n | Label binaire ? |
|---|---:|---|
| gouvernance | 40 | non (exclus) |
| conformite | 17 | non (exclus) |
| **fragilite_financiere** | **7** | oui → fragile |
| performance_operationnelle | 5 | non (exclus) |
| **rien_critique** | **2** | oui → sain |
| strategie | 2 | non (exclus) |
| (absent audit) | 1 | non (exclus) |
| **Total** | **74** | **9 binaires / 65 exclus** |

> **Lecture** : la cause profonde du sample n=38 n'est pas l'absence de PDFs JOAFE mais la **rareté des labels binaires** dans la population CRC. Sur les 162 rapports CRC scrapés, après audit Haiku 4.5, seuls ~50 SIREN sont classés en `fragilite_financiere` ou `rien_critique`. Les autres relèvent de gouvernance, conformité, performance, stratégie — sujets pour lesquels Vigil'Asso n'a pas de prédiction binaire pertinente (c'est un score de fragilité financière, pas un audit qualitatif global).

## Étape 1 — Fetch JOAFE (74 SIREN, 30 min cap)

`scripts/fetch_jo_phase4_v2.rb` a lancé `rake scrape_jo:run Q=SIREN` pour les 74 candidats, copiant les nouveaux PDFs vers `data/pdfs_phase4_v2/`.

| Métrique | Valeur |
|---|---:|
| SIREN tentés | 74 |
| SIREN avec ≥1 PDF | **46 (62 %)** |
| PDFs téléchargés | 500 |
| Moyenne PDFs/SIREN | 10.9 |
| Erreurs rake | 0 |
| Durée | 15.0 min |

Le **taux JOAFE 62 %** est sensiblement plus élevé qu'en BODACC v11 (9 %) ou v8 (13 %). Cohérent : les associations contrôlées par les CRC sont des grosses structures (> 153 k€ de fonds publics) qui déposent davantage que la moyenne. Et inversement, la moyenne 10.9 PDFs/SIREN est très élevée — historique riche.

**Mais** sur les 28 SIREN sans PDF, **les 9 SIREN à label binaire y sont tous présents**. Diagnostic croisé : les associations en `fragilite_financiere` ne déposent quasi jamais leurs comptes annuels au JOAFE — pattern déjà observé sur le sample BODACC. Le segment des défaillantes/à-risque est invisible côté JOAFE.

## Étape 2 — Phase 4 prep + run sur les 46 SIREN avec PDFs

`scripts/phase4_prep_v2.rb` reconstruit `phase4_inputs_v2.csv` (recent + contemp) en lisant uniquement `data/pdfs_phase4_v2/`. La date de publication du rapport CRC est récupérée par jointure sur `reports.csv`.

| Métrique | Valeur |
|---|---:|
| SIREN exploitables | 46 |
| dont label binaire | **0** |
| dont label non-binaire | 46 |
| same_pdf (recent == contemp) | 17 |
| PDFs distincts (recent + contemp) | 28 |
| pas de pdf_contemp (rapport antérieur) | 1 |

`scripts/phase4_run_v2.rb` (appel API Sonnet 4.5 direct, mesure de coût en temps réel) a scoré ces 46 SIREN (output dans `phase4_results_v2.csv`).

| Métrique | Valeur |
|---|---:|
| SIREN traités | 46 |
| Extractions OK | 46 |
| Erreurs | 0 |
| Coût Sonnet 4.5 | **$10.63** |
| Coût moyen / SIREN | $0.231 |
| Coût moyen / PDF distinct | $0.144 |
| Durée | 20.2 min |

## Étape 3 — Recompute matrice CRC

`scripts/recompute_confusion_v2.rb` lit l'union `phase4_results.csv ∪ phase4_results_v2.csv` filtrée sur `expected_label ∈ {fragile, sain}`.

### Résultat

| Sample | n | fragile | sain |
|---|---:|---:|---:|
| v1 (`phase4_results.csv`) | 38 | 25 | 13 |
| v2 (`phase4_results_v2.csv`) | 0 | 0 | 0 |
| **Combiné** | **38** | **25** | **13** |

**v2 n'apporte aucun cas binaire à la matrice.** La matrice de confusion combinée est identique à v1.

### Matrice — combiné n=38, IC Wilson 95 %

#### Seuil C/D/E (T_B=60, alerte recommandée)

|  | Prédit fragile (C/D/E) | Prédit sain (A/B) |
|---|---:|---:|
| **Réel fragile** | **TP=24** | FN=1 |
| **Réel sain** | FP=10 | **TN=3** |

| Métrique | Valeur | IC95 % Wilson |
|---|---:|---|
| Précision | **71 %** | [54 %, 83 %] |
| Rappel | **96 %** | [80 %, 99 %] |
| F1 | 81 % | — |

#### Seuil D/E (T_C=40, alerte forte)

|  | Prédit fragile (D/E) | Prédit sain (A/B/C) |
|---|---:|---:|
| **Réel fragile** | **TP=9** | FN=16 |
| **Réel sain** | FP=2 | **TN=11** |

| Métrique | Valeur | IC95 % Wilson |
|---|---:|---|
| Précision | **82 %** | [52 %, 95 %] |
| Rappel | **36 %** | [20 %, 55 %] |
| F1 | 50 % | — |

### Comparaison v1 vs v2

| Indicateur | v1 (n=38) | v2 (combiné, n=38) | Δ |
|---|---:|---:|---:|
| Précision C/D/E | 71 % | 71 % | 0.0 pt |
| Rappel C/D/E | 96 % | 96 % | 0.0 pt |
| Précision D/E | 82 % | 82 % | 0.0 pt |
| Rappel D/E | 36 % | 36 % | 0.0 pt |

**Les chiffres affichés sur la home (96 %, 7/10 ≈ 71 %) tiennent — par identité, pas par confirmation indépendante.** L'opération n'a pas été un test de robustesse au sens statistique du terme : elle a tenté d'élargir le sample mais l'élargissement effectif est nul. La nouveauté méthodologique est l'**ajout d'IC binomiaux Wilson 95 %**, qui chiffrent objectivement la marge d'erreur des chiffres affichés.

## Analyse exploratoire — 46 SIREN à label non-binaire

Les 46 SIREN scorés (avec rapports CRC sur gouvernance, conformité, performance, stratégie) ne peuvent pas alimenter la matrice binaire mais offrent un éclairage croisé : **comment Vigil'Asso classe-t-il des associations dont la CRC a constaté un problème non-financier ?**

### Distribution par audit_primary × niveau Vigil'Asso

| audit_primary | n | A | B | C | D | E | % alerte (C/D/E) | Score moyen |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| gouvernance | 26 | 0 | 5 | 14 | 7 | 0 | **81 %** | 49.5 |
| conformite | 13 | 1 | 4 | 6 | 2 | 0 | **62 %** | 57.5 |
| performance_operationnelle | 4 | 0 | 2 | 2 | 0 | 0 | 50 % | 60.5 |
| strategie | 2 | 0 | 0 | 1 | 1 | 0 | 100 % | 44.0 |
| (absent audit) | 1 | 0 | 0 | 0 | 1 | 0 | 100 % | 32.0 |
| **Total v2** | **46** | **1** | **11** | **23** | **11** | **0** | **74 %** | 51.4 |
| Référence v1 | 38 | 0 | 4 | 23 | 8 | 3 | 89 % | — |

### Lectures intéressantes

1. **Les rapports CRC « gouvernance » sont à 81 % aussi alertés par Vigil'Asso.** Cela peut signifier (a) que les rapports gouvernance pointent souvent secondairement des fragilités financières, ou (b) que les associations à problèmes de gouvernance ont aussi des signaux financiers dégradés. Distinction non testée dans cette session.
2. **Les rapports CRC « conformité » sont nettement moins alertés (62 %) et ont le score moyen le plus haut (57.5).** Le scoring Vigil'Asso est par construction comptable — il ne capte pas les manquements à la commande publique ou aux statuts.
3. **Aucun niveau E sur les 46 SIREN v2.** Cohérent : v2 ne contient aucun fragile binaire (les défaillantes étaient toutes sans PDF). Les niveaux E v1 viennent intégralement des cas `fragilite_financiere`.
4. **Le taux d'alerte global v2 (74 %) est plus bas que v1 (89 %) sur les fragiles binaires.** Effet attendu : v1 a 66 % de fragile, v2 a 0 %.

Cette analyse est **purement exploratoire** — pas de prédiction validable, pas d'IC à publier. Elle est jointe pour documenter ce qu'on a fait, pas pour étayer un quelconque chiffre produit.

## Pourquoi les 9 SIREN à label binaire n'ont pas de PDF

Hypothèse principale : les associations en `fragilite_financiere` constatée par la CRC ont **arrêté de déposer leurs comptes au JOAFE** plusieurs années avant le constat (souvent au moment où elles entrent en difficulté visible). Le pattern est cohérent avec ce qu'on observe sur le sample BODACC : taux JOAFE 9 % sur les défaillantes, vs 62 % sur les non-défaillantes contrôlées.

Conséquence opérationnelle : **on ne peut pas élargir le sample CRC binaire en scrapant plus de PDFs**. Pour atteindre n ≥ 50 sur la matrice CRC binaire, il faudrait :
- soit re-scraper les CRC pour identifier de nouveaux cas (= reprendre la phase 1 sur ccomptes.fr — coûteux, pas de raison de croire qu'on en aurait beaucoup plus) ;
- soit re-classer en binaire des rapports actuellement étiquetés « gouvernance » qui mentionnent secondairement de la fragilité financière (re-prompt Haiku avec un critère plus permissif — peut être tenté sur le sample audit_pdfs.csv en prochaine session) ;
- soit attendre la **validation prospective** sur le snapshot du 8 mai 2026 (cf. `data/README_snapshots.md`), qui produira un sample externe au CRC.

## Recommandation finale

**Maintenir l'affichage n=38** sur la home et la page méthodologie. Le sample CRC binaire n'a pas changé.

Mises à jour cosmétiques recommandées (à mon avis, à valider) :
- ajouter les **intervalles de confiance Wilson 95 %** à côté des chiffres 96 % et 71 % sur la home — c'est honnête et correspond au caveat « ±15 points » déjà mentionné en méthodologie ;
- ajouter dans la section *Pistes testées et écartées* de la méthodologie une mention courte de cette tentative : « élargissement du sample CRC tenté en mai 2026 — n'a pas permis de récupérer de cas supplémentaire faute de PDFs JOAFE pour les associations fragiles ».

Aucune action recommandée sur `ScoringService`. Décision finale au utilisateur.

## Fichiers produits

| Chemin | Description |
|---|---|
| `scripts/identify_lost_sirens.rb` | Diagnostic + sélection des 74 SIREN |
| `scripts/fetch_jo_phase4_v2.rb` | Scrape JOAFE → `data/pdfs_phase4_v2/` |
| `scripts/phase4_prep_v2.rb` | Construction `phase4_inputs_v2.csv` |
| `scripts/phase4_run_v2.rb` | Extraction + scoring (Sonnet 4.5, cap $15) |
| `scripts/recompute_confusion_v2.rb` | Matrice + IC Wilson |
| `app/assets/fichiers_internes/data/sirens_to_scrape_phase4_v2.csv` | 74 SIREN candidats |
| `app/assets/fichiers_internes/data/phase4_inputs_v2.csv` | 46 SIREN avec PDFs |
| `app/assets/fichiers_internes/data/phase4_results_v2.csv` | 46 SIREN scorés (exploratoire) |
| `data/fetch_jo_phase4_v2_done.csv` | Resume marker fetch |
| `data/pdfs_phase4_v2/` | 500 PDFs scrapés (gitignoré) |
| `ml/CRC_VALIDATION_v2.md` | Ce rapport |

**Aucune modification** de `app/assets/fichiers_internes/data/phase4_results.csv` (l'original v1 est intact). `ScoringService` et les vues sont inchangés.
