# Snapshots prospectifs Vigil'Asso

Ce dossier contient les fichiers `snapshot_prospectif_<YYYY-MM-DD>.csv`, qui figent l'état de scoring courant (`score_vigi`, `niveau_vigi`, sous-scores) de toutes les associations en DB à une date donnée. Ils servent de base pour la **validation prospective** du scoring : mesurer dans 12 à 24 mois combien d'associations alertées (niveau C, D ou E) ont effectivement défailli.

## Schéma CSV

| Colonne | Description |
|---|---|
| `siren` | SIREN de l'association (clé d'appariement BODACC) |
| `cloture` | Date du compte annuel scoré (le plus récent en DB) |
| `nom` | Raison sociale au moment du snapshot |
| `ville` | Ville déclarée au JOAFE |
| `departement` | Département (joint depuis `bodacc_associations_enrichi.csv`) — `null` si absent du fichier d'enrichissement BODACC |
| `ape_section` | Section APE 2 chiffres (joint depuis `bodacc_associations_enrichi.csv`) — `null` si absent |
| `score_vigi` | Score 0-100 calculé par `ScoringService` au moment du snapshot |
| `niveau_vigi` | Niveau A/B/C/D/E correspondant |
| `pts_rent` / `pts_soli` / `pts_liqu` / `pts_auto` / `pts_gouv` | Sous-scores ressortis du `score_detail` jsonb |
| `date_snapshot` | Date de figeage (ISO 8601) — identique au suffixe du fichier |

Chaque ligne correspond à une `Association` en base (table `associations`). Le snapshot est figé : aucune mise à jour ultérieure ne doit modifier ce CSV. Si on veut un nouvel état, on génère un nouveau fichier à une nouvelle date.

## Protocole de validation prospective

Pour mesurer la performance prédictive de Vigil'Asso :

1. **Collecter les jugements BODACC** publiés entre la `date_snapshot` et la date de mesure (T+12 à T+24 mois recommandé).
2. **Apparier** sur `siren` les jugements collectés avec les SIREN listés dans le snapshot.
3. **Calculer le taux de défaillance par niveau initial** A → E (proportion de SIREN du snapshot qui ont reçu un jugement de procédure collective dans la fenêtre).
4. **Reporter** dans `ml/VALIDATION_PROSPECTIVE_<date>.md` : taux par niveau, IC à 95 %, comparaison aux taux attendus si le scoring était parfaitement calibré.

L'hypothèse à tester est que la **probabilité de défaillance croît strictement de A à E**. Quantitativement, on s'attend à des taux de défaillance nettement plus élevés en D/E qu'en A/B.

### Calcul attendu (illustratif)

```
P(défaillance | niveau=N) = (SIREN snapshot niveau=N qui défaillent dans la fenêtre)
                           / (SIREN snapshot niveau=N)
```

Avec un IC binomial à 95 % par niveau (Wilson recommandé pour les petits n).

## Limites à mentionner dans tout rapport public issu de ces snapshots

- **Biais de sélection** : la base actuelle est dominée par les SIREN issus du sample BODACC. La validation prospective sur ce sous-ensemble n'est pas représentative du tissu associatif global.
- **Asymétrie temporelle** : le scoring a été calculé sur des comptes annuels de plusieurs années (souvent antérieurs à 2022). Les associations qui n'ont pas re-déposé depuis ne reçoivent pas de mise à jour de score, ce qui peut artificiellement inflater leurs niveaux D/E sans que cela reflète leur état actuel.
- **Délai BODACC** : un jugement peut intervenir 2-3 ans après le compte scoré ; une fenêtre de 24 mois est un compromis (assez long pour capter du signal, assez court pour rester actionnable).
- **Censure à droite** : à la date de mesure, certaines associations en difficulté n'auront pas encore reçu de jugement BODACC. Le taux observé sous-estime la vraie probabilité.

## Historique des snapshots

| Date | Lignes | Note |
|---|---|---|
| `2026-05-08` | 121 | Snapshot initial — première mesure de validation prospective. |
