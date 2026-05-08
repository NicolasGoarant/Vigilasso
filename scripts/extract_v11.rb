#!/usr/bin/env ruby
# scripts/extract_v11.rb
#
# Extraction Sonnet 4.5 + scoring Vigil'Asso pour chaque PDF JOAFE
# téléchargé pour le sample BODACC v11.
#
# Lance via : bundle exec rails runner scripts/extract_v11.rb
#
# Source PDFs   : data/pdfs_positifs_v11/*.pdf
# Output CSV    : data/scores_positifs_v11.csv (schéma identique à
#                 data/scores_positifs.csv)
# Resume logic  : skip les fichiers déjà présents dans le CSV.
# Rate limit    : sleep 3 s entre extractions, retry expo (30/60/120 s) sur 429.
# Plafond coût  : $100 sur Sonnet 4.5 (input $3/MTok, output $15/MTok).
#                 Au-dessus → arrêt propre.

require 'csv'
require 'set'
require 'ostruct'
require 'base64'

PROJECT_ROOT = File.expand_path('..', __dir__)
PDFS_DIR     = File.join(PROJECT_ROOT, 'data/pdfs_positifs_v11')
OUTPUT_CSV   = File.join(PROJECT_ROOT, 'data/scores_positifs_v11.csv')
LOG_PATH     = '/tmp/extract_v11.log'

MODEL          = 'claude-sonnet-4-5'
MAX_TOKENS     = 1024
SLEEP_BETWEEN  = 3.0
MAX_RETRIES    = 3
COST_CAP_USD   = 100.0

# Tarifs Sonnet 4.5 (USD / MTok)
INPUT_PRICE  = 3.0  / 1_000_000
OUTPUT_PRICE = 15.0 / 1_000_000

CSV_HEADERS = %w[
  fichier siren cloture nom ville
  total_produits resultat_exploitation resultat_net
  fonds_propres tresorerie total_bilan subv_pct
  cac_certifie statut score niveau
  pts_rent pts_soli pts_liqu pts_auto pts_gouv
  error
].freeze

abort "ANTHROPIC_API_KEY manquante." unless ENV['ANTHROPIC_API_KEY']
abort "#{PDFS_DIR} introuvable. Lance d'abord fetch_jo_for_bodacc_v11.rb." unless Dir.exist?(PDFS_DIR)

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

pdfs = Dir.glob(File.join(PDFS_DIR, '*.pdf')).sort
remaining = pdfs.reject { |p| done_files.include?(File.basename(p)) }

# On privilégie les positifs : tri stable sur le nom (déjà fait par .sort).
# La logique « privilégier les positifs » est intrinsèque ici car tous
# les PDFs v11 viennent du sample BODACC (= positifs défaillants).

log "[Extract v11 — Sonnet 4.5]"
log "  PDFs sur disque       : #{pdfs.size}"
log "  Déjà extraits         : #{done_files.size}"
log "  À extraire            : #{remaining.size}"
log "  Modèle                : #{MODEL}"
log "  Plafond coût          : $#{COST_CAP_USD}"
log "  Output                : #{OUTPUT_CSV}"

if remaining.empty?
  log 'Rien à faire.'
  exit 0
end

require 'anthropic'
CLIENT = Anthropic::Client.new(api_key: ENV['ANTHROPIC_API_KEY'])

def call_sonnet_with_usage(pdf_path)
  pdf_data = Base64.strict_encode64(File.binread(pdf_path))
  retries = 0
  usage_h = { input_tokens: 0, output_tokens: 0 }
  begin
    response = CLIENT.messages.create(
      model:      MODEL,
      max_tokens: MAX_TOKENS,
      messages: [
        {
          role: 'user',
          content: [
            { type: 'document',
              source: { type: 'base64', media_type: 'application/pdf', data: pdf_data } },
            { type: 'text', text: ExtractionService::PROMPT }
          ]
        }
      ]
    )
    text = response.content.first.text.gsub(/\A```json\n?/, '').gsub(/\n?```\z/, '').strip
    usage_h = { input_tokens: response.usage.input_tokens, output_tokens: response.usage.output_tokens }
    parsed = JSON.parse(text)
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

def build_assoc(extracted)
  asso = OpenStruct.new(extracted.transform_keys(&:to_s))
  cac = extracted['cac_certifie'] || extracted[:cac_certifie]
  asso.define_singleton_method(:cac_certifie?) { !!cac }
  asso
end

def score_extracted(extracted)
  asso = build_assoc(extracted)
  ScoringService.new(asso).call
end

mode = File.exist?(OUTPUT_CSV) ? 'ab' : 'wb'
total_cost     = 0.0
ok             = 0
errors         = 0
stopped_reason = nil
start          = Time.now

CSV.open(OUTPUT_CSV, mode) do |out|
  out << CSV_HEADERS if mode == 'wb'

  remaining.each_with_index do |pdf_path, idx|
    fichier = File.basename(pdf_path)
    siren = fichier =~ /\A(\d{9})_/ ? $1 : nil
    log "[#{idx + 1}/#{remaining.size}] #{fichier} — coût cumulé $#{format('%.2f', total_cost)}"

    extracted, usage, err = call_sonnet_with_usage(pdf_path)
    cost = usage[:input_tokens] * INPUT_PRICE + usage[:output_tokens] * OUTPUT_PRICE
    total_cost += cost

    if extracted.nil?
      out << [fichier, siren, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, err]
      out.flush
      errors += 1
      log "    ❌ #{err}"
    else
      begin
        scoring = score_extracted(extracted)
        d = scoring[:detail] || {}
        out << [
          fichier,
          extracted['siren'],
          extracted['cloture'],
          extracted['nom'],
          extracted['ville'],
          extracted['total_produits'],
          extracted['resultat_exploitation'],
          extracted['resultat_net'],
          extracted['fonds_propres'],
          extracted['tresorerie'],
          extracted['total_bilan'],
          extracted['subv_sur_produits_pct'],
          extracted['cac_certifie'],
          extracted['statut'],
          scoring[:score],
          scoring[:niveau],
          d[:rentabilite],
          d[:solidite],
          d[:liquidite],
          d[:autonomie],
          d[:gouvernance],
          nil
        ]
        out.flush
        ok += 1
        log "    ✓ niveau=#{scoring[:niveau]} score=#{scoring[:score]} (#{usage[:input_tokens]}in+#{usage[:output_tokens]}out tok, +$#{format('%.4f', cost)})"
      rescue StandardError => e
        out << [fichier, siren, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil,
                "scoring error: #{e.class}: #{e.message[0..150]}"]
        out.flush
        errors += 1
        log "    ❌ scoring error: #{e.message[0..100]}"
      end
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
log '═══ Bilan extract v11 ═══'
log "  durée            : #{(elapsed / 60).round(1)} min"
log "  PDFs traités     : #{ok + errors}"
log "  ok               : #{ok}"
log "  erreurs          : #{errors}"
log "  coût total       : $#{format('%.2f', total_cost)} (plafond $#{COST_CAP_USD})"
log "  arrêt prématuré  : #{stopped_reason || 'non'}"
log "  → #{OUTPUT_CSV}"
log "  → log complet : #{LOG_PATH}"
