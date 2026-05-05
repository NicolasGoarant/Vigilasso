#!/usr/bin/env ruby
# scripts/phase4_run.rb
#
# Phase 4 : extraction + scoring Vigil'Asso pour chaque SIREN, en deux temps :
#   - score_recent  : sur l'exercice JOAFE le plus récent
#   - score_contemp : sur l'exercice contemporain au rapport CRC
#                     (skipé si même PDF que recent)
#
# Lance via : bundle exec rails runner scripts/phase4_run.rb
#
# Resume logic : skip les SIREN déjà dans phase4_results.csv
# Rate limit  : sleep entre extractions, retry sur 429
# Pas de DB   : les scores sont calculés en mémoire via OpenStruct, pas de
#              record Association persisté pour la validation.

require 'csv'
require 'ostruct'

PROJECT_ROOT = File.expand_path('..', __dir__)
DATA_DIR     = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data')
INPUTS_CSV   = File.join(DATA_DIR, 'phase4_inputs.csv')
RESULTS_CSV  = File.join(DATA_DIR, 'phase4_results.csv')

SLEEP_BETWEEN = 3.0   # secondes entre extractions (rate limit safety)
MAX_RETRIES   = 3

abort "#{INPUTS_CSV} introuvable. Lance d'abord phase4_prep.rb." unless File.exist?(INPUTS_CSV)
abort "ANTHROPIC_API_KEY manquante." unless ENV['ANTHROPIC_API_KEY']

# ─── Wrapper pour ScoringService (sans DB) ──────────────────────────

def build_assoc(extracted)
  asso = OpenStruct.new(extracted.transform_keys(&:to_s))
  cac = extracted['cac_certifie'] || extracted[:cac_certifie]
  asso.define_singleton_method(:cac_certifie?) { !!cac }
  asso
end

# ─── Extraction avec retry sur rate limit ───────────────────────────

def extract_with_retry(pdf_path)
  retries = 0
  loop do
    result = ExtractionService.new(pdf_path).call

    if result.is_a?(Hash) && (result[:error] || result['error'])
      err = result[:error] || result['error']
      if err.to_s =~ /429|rate.?limit|overloaded/i && retries < MAX_RETRIES
        retries += 1
        wait = 30 * (2**(retries - 1))  # 30, 60, 120s
        warn "  ⏳ rate limit, sleep #{wait}s (retry #{retries}/#{MAX_RETRIES})"
        sleep wait
        next
      end
      return { error: err }
    end

    return result
  end
end

def score_pdf(pdf_path)
  extracted = extract_with_retry(pdf_path)
  return { error: extracted[:error] } if extracted[:error]

  asso = build_assoc(extracted)
  begin
    scoring = ScoringService.new(asso).call
  rescue StandardError => e
    return { error: "ScoringService : #{e.class} : #{e.message}", extracted: extracted }
  end

  {
    score:        scoring[:score],
    niveau:       scoring[:niveau],
    niveau_text:  scoring[:niveau_text],
    detail:       scoring[:detail],
    extracted:    extracted
  }
end

# ─── Resume logic ────────────────────────────────────────────────────

done_sirens = Set.new
if File.exist?(RESULTS_CSV)
  CSV.foreach(RESULTS_CSV, headers: true) { |r| done_sirens << r['siren'] if r['siren'] }
  puts "  (#{done_sirens.size} SIREN déjà scorés — reprise)"
end

inputs = CSV.read(INPUTS_CSV, headers: true)
remaining = inputs.reject { |r| done_sirens.include?(r['siren']) }

puts ''
puts "[Phase 4] Extraction + scoring Vigil'Asso"
puts "  total inputs   : #{inputs.size}"
puts "  déjà fait      : #{inputs.size - remaining.size}"
puts "  à faire        : #{remaining.size}"
puts "  modèle extract : claude-sonnet-4-5 (via ExtractionService)"
puts ''

# ─── Run ─────────────────────────────────────────────────────────────

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
CSV.open(RESULTS_CSV, mode) do |out|
  out << OUTPUT_HEADER if mode == 'wb'

  remaining.each_with_index do |r, idx|
    siren = r['siren']
    print "  [#{idx + 1}/#{remaining.size}] #{siren} #{r['expected_label'].ljust(7)} #{r['title'].slice(0, 45)}… "

    row = {
      siren:           siren,
      expected_label:  r['expected_label'],
      title:           r['title'],
      age_rapport_crc: r['age_rapport_crc'],
      synthese_crc:    r['synthese_crc']
    }

    # ─── PDF recent ────────────────────────────────────────────────
    pdf_recent = r['pdf_recent_path']
    res_recent = score_pdf(pdf_recent)
    sleep SLEEP_BETWEEN

    if res_recent[:error]
      out << OUTPUT_HEADER.map { |h| row[h.to_sym] || (h == 'error' ? res_recent[:error] : nil) }
      out.flush
      puts "❌ recent: #{res_recent[:error].to_s.slice(0, 50)}"
      next
    end

    row[:recent_pdf]            = r['pdf_recent_basename']
    row[:recent_date]           = r['pdf_recent_date']
    row[:recent_age]            = r['pdf_recent_age']
    row[:recent_score]          = res_recent[:score]
    row[:recent_niveau]         = res_recent[:niveau]
    row[:recent_statut]         = res_recent[:extracted]['statut'] || res_recent[:extracted][:statut]
    row[:recent_resultat_net]   = res_recent[:extracted]['resultat_net'] || res_recent[:extracted][:resultat_net]
    row[:recent_fonds_propres]  = res_recent[:extracted]['fonds_propres'] || res_recent[:extracted][:fonds_propres]
    row[:recent_tresorerie]     = res_recent[:extracted]['tresorerie'] || res_recent[:extracted][:tresorerie]
    row[:recent_detail]         = res_recent[:detail]&.to_json

    # ─── PDF contemporain (si distinct) ────────────────────────────
    pdf_contemp = r['pdf_contemp_path']
    same = r['same_pdf'] == 'true'

    if pdf_contemp && !pdf_contemp.empty? && !same
      res_contemp = score_pdf(pdf_contemp)
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
        row[:contemp_statut]         = res_contemp[:extracted]['statut'] || res_contemp[:extracted][:statut]
        row[:contemp_resultat_net]   = res_contemp[:extracted]['resultat_net'] || res_contemp[:extracted][:resultat_net]
        row[:contemp_fonds_propres]  = res_contemp[:extracted]['fonds_propres'] || res_contemp[:extracted][:fonds_propres]
        row[:contemp_tresorerie]     = res_contemp[:extracted]['tresorerie'] || res_contemp[:extracted][:tresorerie]
        row[:contemp_detail]         = res_contemp[:detail]&.to_json
      end
    elsif same
      # Réutilise les valeurs recent (même PDF)
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

    contemp_str = row[:contemp_score] ? " | contemp #{row[:contemp_niveau]} (#{row[:contemp_score]})" : ''
    puts "✓ recent #{row[:recent_niveau]} (#{row[:recent_score]})#{contemp_str}"
  end
end

# ─── Bilan ───────────────────────────────────────────────────────────

puts ''
puts '═══ Matrice de confusion ═══'
puts ''

rows = CSV.read(RESULTS_CSV, headers: true)

def confusion(rows, niveau_field)
  tp = fp = fn_ = tn = 0
  skipped = 0
  rows.each do |r|
    niveau = r[niveau_field]
    if niveau.to_s.empty?
      skipped += 1
      next
    end
    expected_fragile  = r['expected_label'] == 'fragile'
    predicted_fragile = %w[D E].include?(niveau)
    case [expected_fragile, predicted_fragile]
    when [true, true]   then tp  += 1
    when [false, true]  then fp  += 1
    when [true, false]  then fn_ += 1
    when [false, false] then tn  += 1
    end
  end
  total = tp + fp + fn_ + tn
  precision = (tp + fp).positive? ? tp.to_f / (tp + fp) : 0.0
  recall    = (tp + fn_).positive? ? tp.to_f / (tp + fn_) : 0.0
  f1        = (precision + recall).positive? ? 2 * precision * recall / (precision + recall) : 0.0
  accuracy  = total.positive? ? (tp + tn).to_f / total : 0.0
  { tp: tp, fp: fp, fn: fn_, tn: tn, total: total, skipped: skipped,
    precision: precision, recall: recall, f1: f1, accuracy: accuracy }
end

def show_matrix(label, m)
  puts "── #{label} (n=#{m[:total]}, skipped=#{m[:skipped]}) ──"
  puts "                  prédit fragile (D/E)   prédit sain (A/B/C)"
  puts "  réel fragile          #{m[:tp].to_s.rjust(3)}                    #{m[:fn].to_s.rjust(3)}"
  puts "  réel sain             #{m[:fp].to_s.rjust(3)}                    #{m[:tn].to_s.rjust(3)}"
  puts ""
  puts "  Précision : #{(m[:precision] * 100).round}%   (TP / (TP+FP))"
  puts "  Rappel    : #{(m[:recall] * 100).round}%   (TP / (TP+FN))"
  puts "  F1        : #{(m[:f1] * 100).round}%"
  puts "  Accuracy  : #{(m[:accuracy] * 100).round}%"
  puts ''
end

# Filtres par âge
[
  ['≤ 3 ans (sample principal)',  rows.select { |r| r['age_rapport_crc'].to_f <= 3.0 }],
  ['≤ 5 ans (sample étendu)',     rows.select { |r| r['age_rapport_crc'].to_f <= 5.0 }],
  ['Tous (validation extensive)', rows]
].each do |label, sub|
  next if sub.empty?
  puts ''
  puts "═══ #{label} ═══"
  puts ''
  show_matrix("score_recent (Vigil'Asso scorant les comptes les plus récents)",
              confusion(sub, 'recent_niveau'))
  show_matrix("score_contemp (Vigil'Asso scorant les comptes contemporains du rapport CRC)",
              confusion(sub, 'contemp_niveau'))
end

puts ''
puts "  → #{RESULTS_CSV}"
