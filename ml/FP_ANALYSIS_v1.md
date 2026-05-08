# Analyse des faux positifs CRC v1

**Date** : 2026-05-08
**Sample** : 38 cas du test CRC (`app/assets/fichiers_internes/data/phase4_results.csv`).
**Objectif** : identifier un pattern dans les faux positifs Vigil'Asso → CRC qui justifierait une règle de désalerte dans `ScoringService`, sans dégrader le rappel.

## TL;DR

- **10 faux positifs** identifiés (Vigi C/D/E ∧ CRC sain) — pas 3-4 comme estimé en briefing.
  Matrice de confusion : TP=24, FP=10, FN=1, TN=3 → précision **70.6 %**, rappel **96 %**.
- Catégorisation Haiku 4.5 (10/10 cas) :
  - **(i) Fonds dédiés/affectés : 5 cas**
  - **(ii) Profil sectoriel atypique : 4 cas**
  - **(iii) Volatilité conjoncturelle : 1 cas**
  - (iv) CRC indulgente : 0 cas — (v) Autre : 0 cas.
- **Aucune règle simple testée n'améliore la précision sans casser le rappel.** La règle la plus prometteuse (`rent≥14 ∧ soli≥10 ∧ (auto+liqu)≥12 ∧ niveau=C → B`) corrige **1 FP** et désalerte **3 TP** : précision 70.6 % → 71.9 %, rappel 96 % → 84 %. Trade-off catastrophique.
- **Recommandation : ne pas modifier `ScoringService`.** À n=10 FP, les sous-scores des FP et TP en zone C sont indistinguables. Cause profonde (fonds dédiés, secteur atypique) non détectable depuis les 18 fields actuels.
- Coût Haiku 4.5 : **$0.016** (10 cas × ~$0.0016).

## Liste des 10 faux positifs

| SIREN | Nom | Niveau | Score | Catégorie Haiku | Confidence |
|---|---|---|---:|---:|---|
| 681086740 | Théâtre 71, scène nationale à Malakoff | C | 45 | (ii) | high |
| 379181357 | Culture commune (Pas-de-Calais) | D | 35 | (i) | medium |
| 383554649 | Community (Pas-de-Calais) | C | 51 | (i) | high |
| 815320668 | Gestion associative action culturelle (CE) | C | 47 | (iii) | high |
| 326093655 | Furies (Marne) | C | 56 | (i) | high |
| 439170317 | Office de tourisme intercommunal de Bayeux | C | 56 | (ii) | high |
| 518290713 | Euralens (Pas-de-Calais) | C | 46 | (i) | high |
| 775608979 | Le Clos du Nid (Lozère) | C | 57 | (i) | medium |
| 483168225 | Festival du film de Cabourg | C | 45 | (ii) | high |
| 479806630 | École de management de Normandie | D | 35 | (ii) | high |

7/10 sont en C, 3/10 en D, 0 en E. Score moyen **47.4** (vs 39 pour les vrais positifs C/D/E), donc les FP sont *en moyenne* moins fragiles que les TP — mais pas systématiquement.

## Distribution par catégorie

### Catégorie (i) — Fonds dédiés / affectés (5 cas)

Pattern Haiku récurrent : **trésorerie et fonds propres élevés en valeur absolue, mais largement constitués de subventions affectées non disponibles librement**. Le scoring les comptabilise comme liquidités libres, ce qui dégrade les sous-scores `autonomie` et `liquidité`.

Caractéristiques :
- 5/5 ont `rentabilité` ≥ 14 (positifs ou peu déficitaires).
- 5/5 ont `pts_autonomie` ≤ 8 (souvent ≤ 5) — le scoring sanctionne la dépendance subventions.
- 4/5 ont `pts_gouvernance` = 10 (CAC certifié), 1/5 à 0 (pas de CAC).
- Statut comptable mixte : 3 ambigu, 1 excédent, 1 ambigu.
- Signature financière : `tresorerie ≈ fonds_propres`, ratio « ressources gelées / total bilan » significatif que ScoringService ne mesure pas.

### Catégorie (ii) — Profil sectoriel atypique (4 cas)

Modèles économiques non standards par secteur :
- Scène nationale (Théâtre 71) — dépendance EPCI structurelle.
- Office de tourisme intercommunal — adossé à un EPCI.
- Festival événementiel — flux concentrés annuellement.
- École de management supérieure — quasi-lucrative.

Caractéristiques : très hétérogènes en sous-scores (autonomie de 2.9 à 14.3, liquidité de 0.9 à 15.5). **Aucune signature comptable simple ne les distingue** — c'est l'identité sectorielle qui les caractérise.

### Catégorie (iii) — Volatilité conjoncturelle (1 cas)

815320668 — fusion complexe sur l'exercice analysé. Trop peu de cas pour extrapoler.

### Catégories (iv) et (v) — 0 cas

Aucun cas de « CRC indulgente » ni de cause hors-typologie. Cohérent avec un sample CRC où la conclusion « sain » est plutôt prudente que laxiste.

## Hypothèses de règles testées

### Règle (i) — Buffer financier

```
SI niveau == "C"
   ET pts_rentabilite >= 14
   ET pts_solidite     >= 10
   ET (pts_autonomie + pts_liquidite) >= 12
ALORS désalerter C → B
```

**Résultat sur n=38** :
- FP désalertés : **1/10** (439170317 — Office de tourisme de Bayeux)
- TP désalertés : **3/24** (524906658, 775615370, 780613626 — tous en C borderline)

| Métrique | Avant | Après règle (i) |
|---|---:|---:|
| Précision C/D/E | 24/34 = 70.6 % | 23/32 = 71.9 % |
| Rappel C/D/E | 24/25 = 96 % | 21/25 = **84 %** |
| F1 | 81 % | 77 % |

**Verdict : règle inutilisable.** On gagne 1.3 point de précision pour perdre 12 points de rappel.

### Règle (i) variante stricte

```
SI niveau == "C"
   ET pts_rentabilite >= 14
   ET pts_solidite     >= 10
   ET pts_liquidite    >= 6
   ET tresorerie       >= 0.8 × fonds_propres
   ET fonds_propres    > 0
ALORS désalerter C → B
```

**Résultat** :
- FP désalertés : 2/10
- TP désalertés : 2/24

| Métrique | Après variante stricte |
|---|---:|
| Précision | 22/30 = 73.3 % |
| Rappel | 22/25 = 88 % |
| F1 | 80 % |

Toujours négatif — la perte de rappel reste majeure.

### Règle (ii) — Sectorielle

Implémentation directe impossible : `ScoringService` ne reçoit pas le code APE en entrée, et aucun des 18 fields extraits par `ExtractionService` n'identifie le secteur. Une règle sectorielle nécessiterait :
1. d'enrichir le prompt d'extraction pour produire un champ `secteur_atypique: bool`,
2. ou de joindre à une table externe (BODACC `activite_principale`).

Hors scope de cette analyse.

## Pourquoi aucune règle simple ne fonctionne

Les sous-scores des **FP** et des **TP en zone C** sont quasi-superposés sur la dimension testée :

| Range | FP en C (7) | TP en C (probable, à dériver) |
|---|---|---|
| `rent` | 14.6–15.5 | similaire |
| `soli` | 6.1–22.0 | hétérogène également |
| `auto` | 1.3–8.9 | 11–15 fréquent (mais 524906658 chevauche) |
| `liqu` | 4.8–15.5 | hétérogène |

La cause des FP n'est pas dans les valeurs des sous-scores mais dans **la nature des fonds** (dédiés vs libres) et **l'identité sectorielle**, deux signaux qui ne sont pas dans la signature numérique actuelle. C'est un problème de feature engineering, pas de calibration de seuils.

## Caveat statistique — n=10 ne suffit pas

Avec 10 FP :
- L'intervalle de confiance à 95 % sur la précision est **±15 points** environ.
- Tester une règle qui en touche 1 ou 2 produit du bruit, pas du signal.
- La distribution catégorielle (5 / 4 / 1 / 0 / 0) doit être lue avec prudence — un sample plus large pourrait reclasser certains cas.

Pour identifier un pattern statistiquement significatif, il faudrait soit :
- Un sample CRC élargi (objectif n ≥ 100 cas pour un pouvoir statistique correct),
- Ou un sample BODACC inversé (asso saines confirmées par d'autres sources, p. ex. label IDEAS, Don en confiance) qui Vigil'Asso classe en C/D/E.

## Recommandation

**Ne pas modifier `ScoringService` sur la base de cette analyse.**

Justifications :
1. Aucune règle testée n'améliore le F1.
2. Le sample n=10 FP est trop petit pour calibrer une règle robuste.
3. Les deux catégories majoritaires (i et ii) demandent des features que le scoring ne possède pas — modifier les seuils sans ajouter de feature, c'est jouer à pile ou face.
4. Le rappel 96 % est l'atout principal de Vigil'Asso (peu de fragilités manquées). Le sacrifier pour gagner 1-3 points de précision est contraire à la promesse produit (« couvrir le risque »).

## Pistes pour v12 (hors scope ici)

1. **Feature `secteur_atypique`** : enrichir `ExtractionService` pour identifier scènes nationales, OT, écoles supérieures, festivals — soit via le prompt, soit via jointure APE. Catégorie (ii) couvrirait alors 4/10 FP.
2. **Feature `fonds_dedies_pct`** : ajouter au prompt l'extraction du poste « Fonds dédiés » (présent au passif des asso loi 1901). Catégorie (i) couvrirait alors potentiellement 5/10 FP.
3. **Validation élargie** : retester sur le sample CRC élargi à n=100+ avant de figer une règle.

L'investissement (1) est le plus rentable rapport coût/bénéfice : ajouter un champ booléen au prompt d'extraction est simple, et permettrait de désalerter mécaniquement 4/10 FP avec un risque très réduit sur les TP (un TP rarement est une scène nationale).

## Fichiers produits

| Chemin | Contenu |
|---|---|
| `scripts/analyze_fp.rb` | Script Ruby (Net::HTTP direct, prompts FR, resume logic) |
| `app/assets/fichiers_internes/data/fp_analysis.csv` | 10 FP avec catégorie/reasoning/confidence Haiku |
| `ml/FP_ANALYSIS_v1.md` | Ce rapport |
| `/tmp/analyze_fp.log` | Log d'exécution |

**Aucune modification** de `ScoringService`, `phase4_results.csv`, modèle `Association`, ni vue applicative.
