# Calibration v6 — sweep empirique des seuils Vigil'Asso

**Date** : 2026-05-05
**Script** : `scripts/calibrate_thresholds.rb` (Ruby pur, zéro nouvelle dépendance)
**Recommandation** : **ne pas adopter** les seuils issus du sweep brut combiné. Les seuils actuels sont déjà très proches des optima défendables.

## Composition des samples

| Sample | n | Fragiles | Sains | Taux fragile |
|---|---|---|---|---|
| CRC (validation externe `phase4_results.csv`) | 38 | 25 | 13 | 66 % |
| BODACC (`scores_positifs.csv` + `scores_saines.csv`) | 869 | 111 | 758 | 13 % |
| Combiné | 907 | 136 | 771 | 15 % |

Le déséquilibre du sample BODACC (et son poids 23 fois supérieur au CRC) est le facteur dominant de ce qui suit.

## Métriques aux seuils actuels (T_A=80, T_B=60, T_C=40, T_D=20)

| Sample | Seuil | Précision | Rappel | F1 |
|---|---|---|---|---|
| **CRC** | C/D/E | 71 % | **96 %** | 81 % |
| | D/E | 82 % | 36 % | 50 % |
| **BODACC** | C/D/E | 20 % | 86 % | 33 % |
| | D/E | 38 % | 49 % | 43 % |
| **Combiné** | C/D/E | 23 % | 88 % | 37 % |
| | D/E | 41 % | 46 % | 44 % |

Macro-F1 combinée : **40.3 %**. La précision basse au seuil C/D/E sur BODACC (20 %) traduit un volume massif de FP (382 sur 758 saines) — la majorité des saines BODACC obtient en fait un score < 60.

## Sweep grille (T_B, T_C), step=2, T_B > T_C

730 combinaisons évaluées sur le combiné brut.

### Optimum naïf — combiné brut

**T_B=42, T_C=40** → macro-F1 = **43.7 %** (gain +3.4 pt).

Décomposition :

| Sample | C/D/E F1 | D/E F1 |
|---|---|---|
| CRC | **50 %** ↓ depuis 81 % | 50 % = |
| BODACC | 43 % ↑ depuis 33 % | 43 % = |
| Combiné | 44 % | 44 % |

**Le gain combiné cache une régression sévère sur CRC** : le rappel CRC chute de 96 % à 36 % au seuil C/D/E. Le sweep choisit en pratique de fusionner C/D/E et D/E (T_B et T_C distants de 2 points seulement), ce qui supprime de fait le palier C entre B et D.

### Optima par sample isolé

| Optimisation sur | T_B | T_C | macro-F1 | Distance vs actuel |
|---|---|---|---|---|
| CRC seul | 62 | 60 | 81.4 % | T_B presque inchangé, T_C +20 |
| BODACC seul | 42 | 40 | 42.9 % | T_B −18, T_C inchangé |
| Combiné équilibré (50/50 par source) | 60 | 56 | 57.2 % | T_B inchangé, T_C +16 |

**Lecture** : les seuils actuels (60, 40) coïncident à un point près avec l'optimum CRC seul, et coïncident exactement sur T_B avec l'optimum équilibré. La seule recommandation résiduelle, toutes optimisations confondues, serait de remonter T_C autour de 50–56 pour élargir le seuil D/E.

## Pourquoi ne pas adopter (42, 40)

1. **Le gain combiné est artefactuel.** Il vient à 100 % du sample BODACC, qui pèse 23× le sample CRC dans le combiné non-pondéré. Le sweep optimise en pratique uniquement BODACC, et sacrifie CRC.

2. **Le label BODACC est plus bruité que le label CRC.** Une "saine BODACC" peut être en route vers une procédure collective (lag de plusieurs années entre comptes scorés et dépôt de bilan). Une "défaillante BODACC" peut avoir des comptes encore présentables à la date scorée. Le sample CRC, malgré sa petite taille (n=38), porte une vérité terrain construite par des magistrats financiers — qualitativement plus fiable pour calibrer un seuil d'alerte précoce.

3. **La perte de rappel CRC est massive et irréparable.** Passer de 96 % à 36 % au seuil C/D/E signifie rater deux tiers des associations que la Cour des comptes juge effectivement fragiles. C'est exactement la métrique mise en avant sur la page `/methodologie`.

4. **(42, 40) collapse le système 5 niveaux.** Avec T_B et T_C distants de 2 points, le palier C devient quasi-inexistant. La granularité A/B/C/D/E perd son sens produit (gradation de l'alerte).

5. **L'IC à 95 % couvre tout le gain.** Sur n=38 (sample CRC), l'IC est de ±15 pt par métrique. Sur le combiné, la précision affichée est gonflée par BODACC mais la confiance n'est pas meilleure pour autant — toutes les "améliorations" à ±3 pt sont dans le bruit.

## Si on devait quand même bouger un seuil

Le seul candidat avec une justification cohérente serait **T_C : 40 → 50 (ou 52)**, en gardant T_B=60.

| Effet attendu | Combiné | CRC | BODACC |
|---|---|---|---|
| Rappel D/E | 46 % → ~52 % | 36 % → ~52 % | 49 % → ~52 % |
| Précision D/E | 41 % → ~36 % | 82 % → ~62 % | 38 % → ~33 % |
| F1 D/E | 44 % → ~42 % | 50 % → ~57 % | 43 % → ~40 % |

Vu la sévérité de la perte de précision (qui est l'argument principal du seuil "alerte forte" sur la page méthodologie), je recommande aussi **de ne pas faire ce changement** sans :
- un sample de validation indépendant (au moins 100 cas, pas recouvrant CRC ni BODACC),
- une consultation produit sur la sémantique attendue de "alerte forte" (rappel-prioritaire ou précision-prioritaire ?).

## Recommandation finale

**Garder (T_A=80, T_B=60, T_C=40, T_D=20) inchangés.**

Justification synthétique :
- L'optimum naïf (42, 40) sacrifie la validation CRC pour un gain illusoire sur BODACC bruité.
- L'optimum équilibré confirme que les seuils actuels sont à 0–4 points de l'optimum défendable.
- Un sample de validation indépendant et plus large reste le préalable à toute recalibration sérieuse. Sans ça, on n'apprend qu'à mieux fitter les données qu'on a.

Diagnostic plus actionnable que la calibration elle-même : **le sample BODACC, dans son état actuel, n'est pas un bon outil de calibration**. Il l'est en revanche pour entraîner le modèle ML (étape b). Pour la calibration des seuils du `ScoringService`, prioriser l'élargissement du sample CRC ou la collecte d'un sample dédié.

Aucune modification de `app/services/scoring_service.rb`. Logs bruts dans `/tmp/calibration_v6.log`.
