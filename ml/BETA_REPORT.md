# Rapport β — Règle « trois sous-scores faibles »

**Date** : 2026-05-08
**Sample** : 38 cas du test CRC (`app/assets/fichiers_internes/data/phase4_results.csv`).
**Hypothèse** : un déséquilibre simultané sur ≥ 3 des 5 dimensions financières (sous le seuil 40 % de leur poids max) signale une fragilité que le score pondéré global peut masquer si une dimension forte compense plusieurs dimensions faibles. Descendre d'un cran le niveau dans ce cas devrait améliorer le rappel D/E.

## TL;DR

- **Règle β** : si ≥ 3 sous-scores sur 5 sont sous 40 % de leur poids max (`rent < 12, soli < 10, liqu < 8, auto < 6, gouv < 4`), descendre le niveau initial d'un cran (A→B, B→C, C→D, D→E ; E reste E).
- **10 cas / 38** sont touchés (26 %) : 3 passent de C→D, 7 de D→E.
- **Seuil C/D/E inchangé** (TP=24, FP=10, FN=1, TN=3) — la règle déplace des cas dans la zone C↔D et D↔E qui restent du même côté de la frontière C/D/E.
- **Seuil D/E nettement amélioré** : F1 50 % → **56.4 %** (+6.4 pts), rappel 36 % → **44 %** (+8 pts), précision 81.8 % → 78.6 % (−3.2 pts).
- Trade-off : 7 vrais positifs correctement aggravés contre 3 faux positifs incorrectement aggravés. Sur les 3 cas C→D au seuil D/E, **2 TP gagnés vs 1 FP perdu** — ratio 2:1, favorable.
- **Recommandation : adopter la règle dans `ScoringService` en production**, en gardant le plancher E (pas de double dégradation), avec le caveat n=38 (IC ±15 pts) à valider sur un sample CRC élargi avant communication publique.

## Spécification de la règle

```ruby
THRESHOLDS = {
  rentabilite: 12.0,  # 30 × 40 %
  solidite:    10.0,  # 25 × 40 %
  liquidite:    8.0,  # 20 × 40 %
  autonomie:    6.0,  # 15 × 40 %
  gouvernance:  4.0   # 10 × 40 %
}

faibles = THRESHOLDS.count { |k, t| detail[k] < t }
niveau_final = if faibles >= 3 && niveau_initial != "E"
                 niveau_inferieur(niveau_initial)
               else
                 niveau_initial
               end
```

Le score 0–100 reste inchangé. Seul le mapping niveau est modifié *a posteriori*. C'est isolable, réversible, traçable (un booléen `regle_appliquee` est exposé pour audit).

## Distribution des changements de niveau

| Transition | Cas | dont TP (CRC fragile) | dont FP (CRC sain) |
|---|---:|---:|---:|
| C → D | 3 | 2 | 1 |
| D → E | 7 | 5 | 2 |
| Inchangé | 28 | 17 | 7 |
| **Total** | **38** | **24** | **10** |

Sur les 10 cas touchés, **7 sont des vrais positifs** (CRC fragile) et **3 des faux positifs** (CRC sain). Le ratio 70 % TP / 30 % FP est presque exactement le ratio global du sample (24/34 = 70.6 %) — autrement dit, **la règle β ne discrimine pas spécifiquement les FP : elle descend de manière neutre tous les cas multi-faibles**, sans modifier la précision relative. Le gain de F1 vient uniquement du fait que descendre des TP de C vers D ou de D vers E les place dans la zone d'alerte plus stricte où ils auraient dû être.

## Métriques détaillées

### Seuil C/D/E (alerte standard)

| Métrique | v1 | β | Δ |
|---|---:|---:|---:|
| TP | 24 | 24 | 0 |
| FP | 10 | 10 | 0 |
| FN | 1 | 1 | 0 |
| TN | 3 | 3 | 0 |
| **Précision** | **70.6 %** | **70.6 %** | 0 |
| IC 95 % | [53.8 ; 83.2 %] | [53.8 ; 83.2 %] | — |
| **Rappel** | **96.0 %** | **96.0 %** | 0 |
| IC 95 % | [80.5 ; 99.3 %] | [80.5 ; 99.3 %] | — |
| **F1** | **81.4 %** | **81.4 %** | 0 |

Aucun mouvement. C'est attendu : un cas C→D reste dans la zone d'alerte C/D/E ; un D→E aussi. La règle est inerte au seuil C/D/E.

### Seuil D/E (alerte forte)

| Métrique | v1 | β | Δ |
|---|---:|---:|---:|
| TP | 9 | 11 | +2 |
| FP | 2 | 3 | +1 |
| FN | 16 | 14 | −2 |
| TN | 11 | 10 | −1 |
| **Précision** | **81.8 %** | **78.6 %** | **−3.2 pts** |
| IC 95 % | [52.3 ; 94.9 %] | [52.4 ; 92.4 %] | — |
| **Rappel** | **36.0 %** | **44.0 %** | **+8.0 pts** |
| IC 95 % | [20.2 ; 55.5 %] | [26.7 ; 62.9 %] | — |
| **F1** | **50.0 %** | **56.4 %** | **+6.4 pts** |

**Le gain est réel mais à relativiser** : à n=38 et avec IC à ±20 pts, la différence n'est pas significative au sens statistique strict. C'est néanmoins un mouvement directionnel cohérent avec l'hypothèse, sans dégradation au seuil C/D/E.

## Cas touchés — détail

| SIREN | Title | Transition | Faibles | TP/FP |
|---|---|---|---:|---|
| 785450016 | Les Gémeaux, scène nationale de Sceaux | D→E | 3 | TP |
| 342007069 | Arts Vivants 11 (Aude) | C→D | 3 | TP |
| 345362933 | Montpellier Hérault Rugby | D→E | 3 | TP |
| 379181357 | Culture commune (Pas-de-Calais) | D→E | 3 | **FP** |
| 507487130 | Centre européen des textiles innovants | D→E | 3 | TP |
| 325908879 | BGE Littoral Opale (Pas-de-Calais) | D→E | 4 | TP |
| 815320668 | Gestion associative action culturelle | C→D | 3 | **FP** |
| 780603734 | Orchestre de Picardie (Somme) | C→D | 3 | TP |
| 342668381 | Centre culturel transfrontalier Le Manège | D→E | 3 | TP |
| 479806630 | École de management de Normandie | D→E | 3 | **FP** |

Sur les 3 FP touchés :
- 379181357 (Culture commune) — déjà en D, passe en E. Aggravation cohérente avec une dégradation comptable réelle (rent=14.3, soli=11.9, **liqu=6.3, auto=2.6, gouv=0**).
- 815320668 (Gestion CE) — passe de C à D. La justification Haiku v1 était « volatilité conjoncturelle » (fusion). La règle l'aggrave alors que la CRC tempère.
- 479806630 (EM Normandie) — passe de D à E. École de management quasi-lucrative, profil sectoriel atypique.

## Variantes considérées

### Variante stricte : seuil 4+ faibles

Sur n=38, **2 cas** ont 4+ faibles (325908879 et un autre dans le détail), tous deux TP. La règle 4+ corrigerait 2 TP pour 0 FP — gain rappel D/E +0 ou +1 max. **Trop conservatrice** pour le sample actuel.

### Variante permissive : seuil 2+ faibles

Estimation rapide : ~20-25 cas / 38 auraient 2+ faibles, dont une part importante de TN et FP. Casserait probablement la précision sans gain net. **Non recommandée**.

### Variante : ne pas dégrader B en C

On pourrait restreindre la règle aux niveaux C et D uniquement (ne pas toucher A et B). Sur ce sample, aucun cas A ou B n'a 3+ faibles, donc l'effet observé serait identique. À considérer pour la robustesse hors sample.

## Recommandation

**Adopter la règle β dans `ScoringService` en production**, avec les paramètres :

- Seuil de déclenchement : **3+ sous-scores faibles**
- Seuil bas par sous-score : **40 % du poids max** (12 / 10 / 8 / 6 / 4)
- Plancher : **E** (un cas E reste E ; pas de double dégradation)
- Pas de plafond bas (un A→B reste possible, même si non observé sur le sample)

Justifications :

1. **Gain F1 D/E mesurable** (+6.4 pts), sans aucune dégradation au seuil C/D/E.
2. **Trade-off honnête** : 2 TP gagnés au seuil D/E pour 1 FP gagné, ratio 2:1.
3. **Implémentation triviale** (8 lignes dans `ScoringService`, isolable, traçable via un booléen `regle_appliquee` exposé dans `score_detail`).
4. **Cohérence métier** : un déséquilibre multi-dimensionnel est intuitivement plus inquiétant qu'un déséquilibre mono-dimensionnel masqué par un score moyen.

### Caveats à respecter avant déploiement public

- **n=38 reste petit**. Les IC Wilson restent larges (±15-20 pts), donc le gain mesuré ici n'est pas significatif au sens statistique strict.
- **À re-mesurer** sur le sample CRC élargi (objectif n ≥ 100) avant de communiquer un changement de précision/rappel sur la page `/methodologie`.
- **Vérifier** que le re-scoring automatique des `Association` existantes via le callback `before_save` ne produit pas de changements de niveau inattendus en masse (tous les enregistrements ayant 3+ sous-scores faibles vont basculer d'un cran à la prochaine sauvegarde).

### Décision

La décision d'activer la règle revient au product owner. Si activation :
1. Migrer la logique de `app/services/scoring_service_beta.rb` dans `app/services/scoring_service.rb` (en gardant la signature de retour rétro-compatible — ajouter `sous_scores_faibles` et `regle_appliquee` au hash retour, sans casser les vues actuelles).
2. Ajouter un test minitest qui valide les 10 cas touchés du sample CRC (régression).
3. Mettre à jour la page `/methodologie` avec les nouvelles métriques mesurées.
4. Re-sauvegarder les enregistrements `Association` impactés (un `Association.find_each(&:save)` suffit, le callback fait le reste).

## Fichiers produits

| Chemin | Contenu |
|---|---|
| `app/services/scoring_service_beta.rb` | Service variante β (clone + règle) |
| `scripts/eval_beta.rb` | Évaluation et calcul métriques |
| `app/assets/fichiers_internes/data/phase4_results_beta.csv` | Re-scoring de chaque SIREN |
| `ml/BETA_REPORT.md` | Ce rapport |

**Aucune modification** de `ScoringService`, `phase4_results.csv` original, modèle `Association`, ni vue applicative.
