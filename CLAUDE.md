# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Vigil'Asso** — a Rails 7.2 app + research pipeline for scoring the financial fragility of French *associations loi 1901*. The product surface is a small Rails CRUD on top of two AI-driven services; most of the repo's mass is offline data pipelines (Ruby scripts + rake tasks + Python ML) that built and validated the scoring methodology.

## Stack & prerequisites

- Ruby 3.3.0 (`.ruby-version`), Rails 7.2.3, PostgreSQL, Puma, importmap, Hotwire (Turbo + Stimulus), Tailwind (`tailwindcss-rails`), Active Storage for PDF uploads.
- `anthropic` gem (1.24) — both the gem and direct `Net::HTTP` calls to `api.anthropic.com` are used.
- `pdftotext` (poppler-utils) is required by the rake/script PDF pipelines.
- Python 3 + scikit-learn / pandas for `ml/` (no requirements file — install ad hoc).
- `ANTHROPIC_API_KEY` must be set in `.env` (loaded via `dotenv-rails` in dev/test).

## Common commands

```bash
bin/setup                 # bundle, db:prepare, etc.
bin/dev                   # foreman: rails s + tailwindcss:watch (Procfile.dev)
bin/rails server          # web only
bin/rails db:migrate
bin/rails console
bin/rubocop               # rails-omakase rules
bin/brakeman              # security scan
```

Tests use the standard Rails minitest layout (`bin/rails test`, `bin/rails test test/path/file_test.rb:LINE`). There is currently no meaningful test suite — assume work-in-progress.

### Pipeline tasks (rake)

```bash
rake scrape_jo:run                           # download JOAFE PDFs to tmp/jo_pdfs/
rake scrape_jo:run Q="MJC" DRY_RUN=true MAX_ROWS=200
rake extract_financials:run                  # Haiku extraction → CompteAnnuel rows
rake extract_financials:run LIMIT=50 RETRY_ERRORS=true
rake extract_financials:run PDF=779884329_31082022
rake extract_financials:stats
rake bodacc:import                           # imports data/scores_positifs.csv + bodacc_*.csv into Association
```

### Research scripts

Most scripts under `scripts/` are one-off / phased pipeline steps with **resume logic** (re-running skips work already in the output CSV). Run with `bundle exec rails runner scripts/<name>.rb` when they need ActiveRecord, otherwise plain `ruby`. Read each script's header comment first — they document phase, inputs, outputs, cost, and duration.

Key flow: `crc_validator.rb` (CRC reports → SIREN matching via Haiku arbitration) → `audit_pdfs.rb` (categorize report subjects) → `build_phase3_csv.rb` → `phase4_prep.rb` (find recent + contemporaneous JOAFE PDFs per SIREN) → `phase4_run.rb` (extract + score both, in-memory via OpenStruct, no DB persistence).

### ML

```bash
python ml/prepare_dataset.py    # builds ml/data/dataset.csv
python ml/train_final.py        # canonical balanced RF eval (referenced in commit messages)
```

Other `train_*.py` are alternative experiments (imputation, sector ratios, meta features). The commit log is authoritative on which one is current — see notes like "v5.1 : ratios sectoriels (rappel 71% → 85%)".

## Architecture

### Web app (small, ~2 controllers)

- Routes: `root pages#home` + `resources :associations` with `member :relancer_extraction` and `collection :export`. Everything is at `/associations/*`.
- `PagesController#home` is the institutional landing page (single ERB file with inline styles, targets *élus* / collectivités).
- `AssociationsController` does CRUD + batch PDF upload (≤ `MAX_PDFS = 10`/batch) + CSV export. The `create` action runs `ExtractionService` synchronously per PDF in the request — there is no background job, so large uploads block the web worker.

### Two services that do all the real work

**`ExtractionService`** (`app/services/extraction_service.rb`) — sends a PDF to **`claude-sonnet-4-5`** as a base64 `document` block with a French expert-comptable prompt, expects a strict JSON response with ~17 financial fields. Used by the live web flow.

**`ScoringService`** (`app/services/scoring_service.rb`) — pure-Ruby, zero I/O. Computes a 0–100 score from 5 weighted ratios (rentabilité 30 / solidité 25 / liquidité 20 / autonomie 15 / gouvernance 10) and maps to grade A–E. The score is recomputed automatically by `Association#calculer_score` (a `before_save` callback), so any field update re-derives `score_vigi`, `niveau_vigi`, `score_detail`. **Two consequences:** (1) Tests/scripts can score without DB by passing any object that responds to the same methods — see `scripts/phase4_run.rb` which uses `OpenStruct` with `cac_certifie?` injected. (2) Editing scoring weights changes scores on next save of every record, not retroactively until touched.

### Two extraction paths (intentional, different costs/inputs)

| | Web (`ExtractionService`) | Pipeline (`extract_financials.rake`) |
|---|---|---|
| Model | `claude-sonnet-4-5` | `claude-haiku-4-5-20251001` |
| Input | base64 PDF | `pdftotext` plaintext (first 12k chars) |
| SDK | `anthropic` gem | raw `Net::HTTP` |
| Persists to | `Association` | `CompteAnnuel` |
| Field set | scoring-oriented (~17 fields incl. ratios %, CAC, statut) | raw P&L + bilan (~20 fields, no ratios) |

They are not interchangeable. `Association` is the user-facing scored record. `CompteAnnuel` is research substrate built from the JOAFE bulk download — it has no association to `Association` other than `siren`. `bodacc:import` is what populates `Association` rows from the CSV outputs of the offline pipeline.

### Data model essentials

- `Association` has `has_one_attached :pdf`, unique index on `[siren, cloture]`, `statut` enum (`excedent/deficit/ambigu`), nullable BODACC defaillance fields (`defaillance_bodacc`, `date_jugement`, `nature_jugement`), and the score triplet (`score_vigi`, `niveau_vigi`, `score_detail` jsonb). Useful scopes: `defaillantes`, `saines`, `non_labellises`, `avec_pdf`, `deficitaires`.
- `CompteAnnuel` is keyed by `jo_id` (= JOAFE filename `{SIREN}_{DDMMYYYY}`), stores `statut` ∈ `{ok, vide, erreur}` plus the raw extracted JSON.

### Where data lives

- `tmp/jo_pdfs/` — downloaded JOAFE PDFs (gitignored). Filename pattern `{siren}_{ddmmyyyy}.pdf` is the canonical key, parsed in many places.
- `data/` and root-level `bodacc_*.csv` — pipeline outputs, committed (these are the *inputs* to `bodacc:import`).
- `app/assets/fichiers_internes/data/` — CRC scraper outputs (`reports.csv`, `sirens_verified.csv`, `phase4_*.csv`). Committed.
- `ml/data/dataset.csv` — unified labeled dataset for ML training.

## Conventions worth knowing

- French throughout: column names, prompts, error messages, UI strings, commit messages. Match it when adding code.
- Rubocop is `rails-omakase`; don't fight it.
- The repo has no CI hook or pre-commit hook configured. `bin/rubocop` and `bin/brakeman` are manual.
- Commit history uses versioned product milestones ("Vigil'Asso v5.1", "Phase 4", etc.) — read recent commits before larger changes; methodology decisions are documented there, not in markdown.

## Préférences de développement

- Réponses concises et directes, en français.
- Ruby et bash exclusivement pour les scripts. Pas de Python pour de l'écriture de fichiers ou des manipulations qui peuvent se faire en Ruby.
- Réécritures complètes de fichier plutôt que patches partiels quand il s'agit de scripts standalone (`scripts/`). Les fichiers Rails (controllers, models, views) suivent le pattern habituel d'edits ciblés.
- Commandes terminal copy-paste-ready dans les explications, avec leur cwd quand c'est utile.
- Avant tout chantier non-trivial : montrer le plan en quelques lignes et attendre validation, ne pas partir tête baissée.
- Pour les visualisations de données dans des vues Rails : SVG inline d'abord (zéro dépendance), Chartkick si besoin de quelque chose d'interactif. Pas de framework JS lourd.
- Tailwind v4 avec safelist — vérifier `app/assets/stylesheets/safelist.txt` avant d'utiliser une utility class non-évidente.
- Honnêteté méthodologique : ne pas surdimensionner les chiffres ni masquer les limites. Sample n=38 = intervalles de confiance ±15 points, à mentionner systématiquement quand on présente la validation CRC.

## État courant (mai 2026)

- **Phase de validation CRC terminée.** 162 rapports CRC scrapés → 116 SIREN identifiés (Haiku arbitre) → 53 cas exploitables après audit qualitatif → 38 scorés (les autres sans PDF JOAFE ou exercice trop ancien). Résultats dans `app/assets/fichiers_internes/data/phase4_results.csv`.
- **Métriques de référence** au seuil C/D/E (= alerte) sur n=38 : précision 71%, rappel 96%, F1 81%. Au seuil D/E (alerte forte) : précision 82%, rappel 36%, F1 50%.
- **Prochain chantier** : page `/methodologie` qui présente cette validation publiquement (protocole, sources, matrice de confusion, limites). À intégrer dans le style des pages existantes.
- **Limitations connues à mentionner dans tout narratif public** : sample n=38, définition "fragile" CRC partiellement non-financière, biais de sélection (CRC contrôle les assos > 153k€), validation pas totalement indépendante (les seuils du scoring ont pu être calibrés sur des données du même type).
