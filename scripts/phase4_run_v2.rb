#!/usr/bin/env ruby
# scripts/phase4_run_v2.rb
#
# Adaptation de scripts/phase4_run.rb pour la vague v2.
#
# Diffère de la version v1 :
#   - Lit phase4_inputs_v2.csv et écrit phase4_results_v2.csv
#     (l'original phase4_results.csv N'EST PAS modifié).
#   - Plafond strict $15 sur Sonnet 4.5, mesuré par usage réel (input/output
#     tokens retournés par l'API), pattern emprunté à scripts/extract_v11.rb.
#   - Resume logic identique (skip les SIREN déjà dans phase4_results_v2.csv).
#
# Lance via : bundle exec rails runner scripts/phase4_run_v2.rb

require 'csv'
require 'set'
require 'ostruct'
require 'base64'
require 'anthropic'

PROJECT_ROOT = File.expand_path('..', __dir__)
DATA_DIR     = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data')
INPUTS_CSV   = File.join(DATA_DIR, 'phase4_inputs_v2.csv')
RESULTS_CSV  = File.join(DATA_DIR, 'phase4_results_v2.csv')
LOG_PATH     = '/tmp/phase4_run_v2.log'

MODEL          = 'claude-sonnet-4-5'
MAX_TOKENS     = 1024
SLEEP_BETWEEN  = 3.0
MAX_RETRIES    = 3
COST_CAP_USD   = 15.0

INPUT_PRICE  = 3.0  / 1_000_000
OUTPUT_PRICE = 15.0 / 1_000_000

abort "#{INPUTS_CSV} introuvable. Lance d'abord phase4_prep_v2.rb." unless File.exist?(INPUTS_CSV)
abort "ANTHROPIC_API_KEY manquante." unless ENV['ANTHROPIC_API_KEY']

LOG = File.open(LOG_PATH, 'a')
LOG.sync = true
def log(msg)
  line = "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
  puts line
  LOG.puts line
end

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

def score_pdf_real(pdf_path)
  extracted, usage, err = call_sonnet_with_usage(pdf_path)
  cost = usage[:input_tokens] * INPUT_PRICE + usage[:output_tokens] * OUTPUT_PRICE
  return { error: err, cost: cost, usage: usage } if extracted.nil?

  asso = build_assoc(extracted)
  begin
    scoring = ScoringService.new(asso).call
  rescue StandardError => e
    return { error: "ScoringService : #{e.class} : #{e.message}", cost: cost, usage: usage, extracted: extracted }
  end

  {
    score:        scoring[:score],
    niveau:       scoring[:niveau],
    detail:       scoring[:detail],
    extracted:    extracted,
    cost:         cost,
    usage:        usage
  }
end

# ─── Resume ──────────────────────────────────────────────────────────

done_sirens = Set.new
if File.exist?(RESULTS_CSV)
  CSV.foreach(RESULTS_CSV, headers: true) { |r| done_sirens << r['siren'] if r['siren'] }
end

inputs = CSV.read(INPUTS_CSV, headers: true)
remaining = inputs.reject { |r| done_sirens.include?(r['siren']) }

log "[Phase 4 v2 — extraction + scoring]"
log "  total inputs   : #{inputs.size}"
log "  déjà fait      : #{inputs.size - remaining.size}"
log "  à faire        : #{remaining.size}"
log "  modèle         : #{MODEL}"
log "  plafond coût   : $#{COST_CAP_USD}"

OUTPUT_HEADER = %w[
  siren expected_label title age_rapport_crc synthese_crc
  recent_pdf recent_date recent_age
  recent_score recent_niveau recent_statut
  recent_resultat_net recent_fonds_propres recent_tresorerie
  recent_detail
  contemp_pdf contemp_date contemp_lag
  contemp_score contemp_niveau contemp_statut
  contemp_resultat_net contemp_fonds_propres contemp_tresorerie
  contemp_detail
  error
].freeze

mode = File.exist?(RESULTS_CSV) ? 'ab' : 'wb'
total_cost = 0.0
ok = 0
errors = 0
stopped_reason = nil
start = Time.now

CSV.open(RESULTS_CSV, mode) do |out|
  out << OUTPUT_HEADER if mode == 'wb'

  remaining.each_with_index do |r, idx|
    siren = r['siren']
    label_short = r['expected_label'].to_s.empty? ? '(non-bin)' : r['expected_label'].ljust(7)
    log "[#{idx + 1}/#{remaining.size}] #{siren} #{label_short} — coût cumulé $#{format('%.2f', total_cost)}"

    row = {
      siren:           siren,
      expected_label:  r['expected_label'],
      title:           r['title'],
      age_rapport_crc: r['age_rapport_crc'],
      synthese_crc:    r['synthese_crc']
    }

    pdf_recent = r['pdf_recent_path']
    res_recent = score_pdf_real(pdf_recent)
    total_cost += res_recent[:cost] || 0.0
    sleep SLEEP_BETWEEN

    if res_recent[:error]
      out << OUTPUT_HEADER.map { |h| row[h.to_sym] || (h == 'error' ? res_recent[:error] : nil) }
      out.flush
      errors += 1
      log "    ❌ recent: #{res_recent[:error].to_s.slice(0, 80)} (#{res_recent[:usage][:input_tokens]}in+#{res_recent[:usage][:output_tokens]}out tok, +$#{format('%.4f', res_recent[:cost])})"
      if total_cost > COST_CAP_USD
        stopped_reason = "plafond $#{COST_CAP_USD} atteint (cumul $#{format('%.2f', total_cost)})"
        log "🛑 #{stopped_reason}"
        break
      end
      next
    end

    row[:recent_pdf]            = r['pdf_recent_basename']
    row[:recent_date]           = r['pdf_recent_date']
    row[:recent_age]            = r['pdf_recent_age']
    row[:recent_score]          = res_recent[:score]
    row[:recent_niveau]         = res_recent[:niveau]
    row[:recent_statut]         = res_recent[:extracted]['statut']
    row[:recent_resultat_net]   = res_recent[:extracted]['resultat_net']
    row[:recent_fonds_propres]  = res_recent[:extracted]['fonds_propres']
    row[:recent_tresorerie]     = res_recent[:extracted]['tresorerie']
    row[:recent_detail]         = res_recent[:detail]&.to_json

    pdf_contemp = r['pdf_contemp_path']
    same = r['same_pdf'] == 'true'

    if pdf_contemp && !pdf_contemp.empty? && !same
      if total_cost >= COST_CAP_USD
        out << OUTPUT_HEADER.map { |h| row[h.to_sym] }
        out.flush
        ok += 1
        stopped_reason = "plafond $#{COST_CAP_USD} atteint avant contemp"
        log "🛑 #{stopped_reason} — recent OK, contemp skipped"
        break
      end

      res_contemp = score_pdf_real(pdf_contemp)
      total_cost += res_contemp[:cost] || 0.0
      sleep SLEEP_BETWEEN

      if res_contemp[:error]
        row[:contemp_pdf] = r['pdf_contemp_basename']
        row[:error]       = "contemp: #{res_contemp[:error]}"
      else
        row[:contemp_pdf]            = r['pdf_contemp_basename']
        row[:contemp_date]           = r['pdf_contemp_date']
        row[:contemp_lag]            = r['pdf_contemp_lag']
        row[:contemp_score]          = res_contemp[:score]
        row[:contemp_niveau]         = res_contemp[:niveau]
        row[:contemp_statut]         = res_contemp[:extracted]['statut']
        row[:contemp_resultat_net]   = res_contemp[:extracted]['resultat_net']
        row[:contemp_fonds_propres]  = res_contemp[:extracted]['fonds_propres']
        row[:contemp_tresorerie]     = res_contemp[:extracted]['tresorerie']
        row[:contemp_detail]         = res_contemp[:detail]&.to_json
      end
    elsif same
      row[:contemp_pdf]            = r['pdf_recent_basename']
      row[:contemp_date]           = r['pdf_recent_date']
      row[:contemp_lag]            = nil
      row[:contemp_score]          = res_recent[:score]
      row[:contemp_niveau]         = res_recent[:niveau]
      row[:contemp_statut]         = row[:recent_statut]
      row[:contemp_resultat_net]   = row[:recent_resultat_net]
      row[:contemp_fonds_propres]  = row[:recent_fonds_propres]
      row[:contemp_tresorerie]     = row[:recent_tresorerie]
      row[:contemp_detail]         = row[:recent_detail]
    end

    out << OUTPUT_HEADER.map { |h| row[h.to_sym] }
    out.flush
    ok += 1

    contemp_str = row[:contemp_score] ? " | contemp #{row[:contemp_niveau]}(#{row[:contemp_score]})" : ''
    log "    ✓ recent #{row[:recent_niveau]}(#{row[:recent_score]})#{contemp_str} (+$#{format('%.4f', res_recent[:cost])})"

    if total_cost > COST_CAP_USD
      stopped_reason = "plafond $#{COST_CAP_USD} atteint (cumul $#{format('%.2f', total_cost)})"
      log "🛑 #{stopped_reason}"
      break
    end
  end
end

elapsed = Time.now - start
log ''
log '═══ Bilan phase4_run_v2 ═══'
log "  durée            : #{(elapsed / 60).round(1)} min"
log "  SIREN traités    : #{ok + errors}"
log "  ok               : #{ok}"
log "  erreurs          : #{errors}"
log "  coût total       : $#{format('%.2f', total_cost)} (plafond $#{COST_CAP_USD})"
log "  arrêt prématuré  : #{stopped_reason || 'non'}"
log "  → #{RESULTS_CSV}"
log "  → log : #{LOG_PATH}"
