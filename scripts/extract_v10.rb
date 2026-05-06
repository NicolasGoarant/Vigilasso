#!/usr/bin/env ruby
# scripts/extract_v10.rb
#
# Étape 2b ML : ré-extraction enrichie des 400 PDFs sample v10
# (200 positifs + 200 saines) via ExtractionServiceEnriched.
#
# Lance via : bundle exec rails runner scripts/extract_v10.rb
#
# Input  : data/pdfs_sample_v10.csv (pdf_path, fichier, siren, cloture, label)
# Output : data/scores_v10.csv (champs comptables habituels + 2 nouveaux Sonnet :
#          cac_certification_qualite, concentration_financeurs)
# Resume : skip les fichiers déjà présents dans le CSV de sortie.
# Rate limit : sleep 3s entre extractions, retry expo (30s, 60s, 120s) sur 429.
# Plafond coût : $50 strict (Sonnet 4.5 : input $3/MTok, output $15/MTok).
#                Au-dessus → arrêt propre, on écrit ce qu'on a et on log.

require 'csv'
require 'set'
require 'ostruct'
require 'base64'
require 'anthropic'

PROJECT_ROOT = File.expand_path('..', __dir__)
SAMPLE_CSV   = File.join(PROJECT_ROOT, 'data/pdfs_sample_v10.csv')
OUTPUT_CSV   = File.join(PROJECT_ROOT, 'data/scores_v10.csv')
LOG_PATH     = '/tmp/extract_v10.log'

MODEL          = 'claude-sonnet-4-5'
SLEEP_BETWEEN  = 3.0
MAX_RETRIES    = 3
COST_CAP_USD   = 50.0

INPUT_PRICE  = 3.0  / 1_000_000
OUTPUT_PRICE = 15.0 / 1_000_000

CSV_HEADERS = %w[
  fichier siren cloture nom ville label
  total_produits resultat_exploitation resultat_net
  fonds_propres tresorerie emprunts total_bilan
  subv_pct masse_sal_pct fp_bilan_pct etp
  cac_certifie statut
  cac_certification_qualite concentration_financeurs
  notes
  input_tokens output_tokens cost_usd
  error
].freeze

abort "ANTHROPIC_API_KEY manquante." unless ENV['ANTHROPIC_API_KEY']
abort "#{SAMPLE_CSV} introuvable. Lance d'abord select_pdfs_v10.rb." unless File.exist?(SAMPLE_CSV)

LOG = File.open(LOG_PATH, 'a')
LOG.sync = true
def log(msg)
  line = "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
  puts line
  LOG.puts line
end

# ─── Resume ──────────────────────────────────────────────────────────

done_files = Set.new
if File.exist?(OUTPUT_CSV)
  CSV.foreach(OUTPUT_CSV, headers: true) { |r| done_files << r['fichier'] if r['fichier'] }
end

sample = CSV.read(SAMPLE_CSV, headers: true)
remaining = sample.reject { |r| done_files.include?(r['fichier']) }

log "[Extract v10 — Sonnet 4.5 enrichi]"
log "  PDFs sample           : #{sample.size}"
log "  Déjà extraits         : #{done_files.size}"
log "  À extraire            : #{remaining.size}"
log "  Modèle                : #{MODEL}"
log "  Plafond coût          : $#{COST_CAP_USD}"
log "  Output                : #{OUTPUT_CSV}"

if remaining.empty?
  log 'Rien à faire.'
  exit 0
end

CLIENT = Anthropic::Client.new(api_key: ENV['ANTHROPIC_API_KEY'])

def call_sonnet(pdf_path)
  pdf_data = Base64.strict_encode64(File.binread(pdf_path))
  retries = 0
  usage_h = { input_tokens: 0, output_tokens: 0 }
  raw = nil
  begin
    response = CLIENT.messages.create(
      model:      MODEL,
      max_tokens: 1500,
      messages: [
        {
          role: 'user',
          content: [
            { type: 'document',
              source: { type: 'base64', media_type: 'application/pdf', data: pdf_data } },
            { type: 'text', text: ExtractionServiceEnriched::PROMPT }
          ]
        }
      ]
    )
    usage_h = { input_tokens: response.usage.input_tokens, output_tokens: response.usage.output_tokens }
    raw = response.content.first.text.gsub(/\A```json\n?/, '').gsub(/\n?```\z/, '').strip
    parsed = JSON.parse(raw)
    parsed = ExtractionServiceEnriched.normalize_static(parsed)
    [parsed, usage_h, nil]
  rescue JSON::ParserError => e
    [nil, usage_h, "JSON invalide: #{e.message[0..150]}"]
  rescue StandardError => e
    if e.message =~ /429|rate.?limit|overloaded/i && retries < MAX_RETRIES
      retries += 1
      wait = 30 * (2**(retries - 1))
      log "    ⏳ rate limit, sleep #{wait}s (retry #{retries}/#{MAX_RETRIES})"
      sleep wait
      retry
    end
    [nil, usage_h, "#{e.class}: #{e.message[0..200]}"]
  end
end

# ─── Run ─────────────────────────────────────────────────────────────

mode = File.exist?(OUTPUT_CSV) ? 'ab' : 'wb'
total_cost     = 0.0
ok             = 0
errors         = 0
stopped_reason = nil
start          = Time.now

CSV.open(OUTPUT_CSV, mode) do |out|
  out << CSV_HEADERS if mode == 'wb'

  remaining.each_with_index do |row, idx|
    pdf_path = row['pdf_path']
    fichier  = row['fichier']
    siren    = row['siren']
    cloture  = row['cloture']
    label    = row['label']

    log "[#{idx + 1}/#{remaining.size}] #{fichier} (label=#{label}) — coût $#{format('%.2f', total_cost)}"

    unless File.exist?(pdf_path)
      out << [fichier, siren, cloture, nil, nil, label, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, 0, 0, 0, 'pdf_introuvable']
      out.flush
      errors += 1
      log "    ❌ PDF introuvable : #{pdf_path}"
      next
    end

    parsed, usage, err = call_sonnet(pdf_path)
    cost = usage[:input_tokens] * INPUT_PRICE + usage[:output_tokens] * OUTPUT_PRICE
    total_cost += cost

    if parsed.nil?
      out << [fichier, siren, cloture, nil, nil, label, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
              usage[:input_tokens], usage[:output_tokens], cost.round(5), err]
      out.flush
      errors += 1
      log "    ❌ #{err}"
    else
      out << [
        fichier,
        parsed['siren'] || siren,
        parsed['cloture'] || cloture,
        parsed['nom'],
        parsed['ville'],
        label,
        parsed['total_produits'],
        parsed['resultat_exploitation'],
        parsed['resultat_net'],
        parsed['fonds_propres'],
        parsed['tresorerie'],
        parsed['emprunts'],
        parsed['total_bilan'],
        parsed['subv_sur_produits_pct'],
        parsed['masse_sal_pct'],
        parsed['fp_bilan_pct'],
        parsed['etp'],
        parsed['cac_certifie'],
        parsed['statut'],
        parsed['cac_certification_qualite'],
        parsed['concentration_financeurs'],
        parsed['notes'],
        usage[:input_tokens],
        usage[:output_tokens],
        cost.round(5),
        nil
      ]
      out.flush
      ok += 1
      cq = parsed['cac_certification_qualite'] || '-'
      cf = parsed['concentration_financeurs'] || '-'
      log "    ✓ cac_q=#{cq} conc_fin=#{cf} (#{usage[:input_tokens]}in+#{usage[:output_tokens]}out, +$#{format('%.4f', cost)})"
    end

    if total_cost > COST_CAP_USD
      stopped_reason = "plafond $#{COST_CAP_USD} atteint (cumul $#{format('%.2f', total_cost)})"
      log "🛑 #{stopped_reason} — arrêt propre"
      break
    end

    sleep SLEEP_BETWEEN
  end
end

elapsed = Time.now - start
log ''
log '═══ Bilan extract v10 ═══'
log "  durée            : #{(elapsed / 60).round(1)} min"
log "  PDFs traités     : #{ok + errors}"
log "  ok               : #{ok}"
log "  erreurs          : #{errors}"
log "  coût total       : $#{format('%.2f', total_cost)} (plafond $#{COST_CAP_USD})"
log "  arrêt prématuré  : #{stopped_reason || 'non'}"
log "  → #{OUTPUT_CSV}"
log "  → log complet : #{LOG_PATH}"
