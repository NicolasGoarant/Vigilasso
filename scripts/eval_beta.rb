#!/usr/bin/env ruby
# scripts/eval_beta.rb
#
# Évalue la règle β (trois sous-scores faibles → désalerte) sur le sample
# CRC n=38. Les sous-scores du compte récent sont lus directement depuis
# phase4_results.csv → recent_detail (JSON).
#
# Output :
#   app/assets/fichiers_internes/data/phase4_results_beta.csv
#     (siren, expected_label, recent_score, niveau_v1, niveau_beta, faibles, regle_appliquee)
#
# Métriques précision / rappel / F1 + IC Wilson 95 % aux seuils C/D/E
# et D/E pour v1 et β, imprimées en console et reprises dans
# ml/BETA_REPORT.md.
#
# Lance via : bundle exec rails runner scripts/eval_beta.rb

require 'csv'
require 'json'

PROJECT_ROOT = File.expand_path('..', __dir__)
INPUT_CSV    = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data/phase4_results.csv')
OUTPUT_CSV   = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data/phase4_results_beta.csv')

abort "#{INPUT_CSV} introuvable." unless File.exist?(INPUT_CSV)

WEIGHTS    = ScoringService::WEIGHTS
THRESHOLDS = {
  rentabilite: WEIGHTS[:rentabilite] * 0.4,
  solidite:    WEIGHTS[:solidite]    * 0.4,
  liquidite:   WEIGHTS[:liquidite]   * 0.4,
  autonomie:   WEIGHTS[:autonomie]   * 0.4,
  gouvernance: WEIGHTS[:gouvernance] * 0.4
}.freeze

DOWN = { 'A' => 'B', 'B' => 'C', 'C' => 'D', 'D' => 'E', 'E' => 'E' }.freeze

def beta_niveau(niveau_v1, detail)
  faibles = THRESHOLDS.count { |k, t| detail[k.to_s].to_f < t }
  if faibles >= 3 && niveau_v1 != 'E'
    [DOWN[niveau_v1], faibles, true]
  else
    [niveau_v1, faibles, false]
  end
end

# ─── Re-niveau β sur les 38 SIREN ───────────────────────────────────

rows = []
CSV.foreach(INPUT_CSV, headers: true) do |r|
  next if r['error'] && !r['error'].to_s.empty?
  next unless r['recent_niveau'] && r['recent_detail']
  detail = JSON.parse(r['recent_detail']) rescue {}
  niveau_v1 = r['recent_niveau']
  niveau_beta, faibles, applied = beta_niveau(niveau_v1, detail)

  rows << {
    siren: r['siren'],
    title: r['title'],
    expected_label: r['expected_label'],
    recent_score: r['recent_score'].to_i,
    niveau_v1: niveau_v1,
    niveau_beta: niveau_beta,
    faibles: faibles,
    regle_appliquee: applied,
    detail: detail
  }
end

CSV.open(OUTPUT_CSV, 'wb') do |out|
  out << %w[siren expected_label recent_score niveau_v1 niveau_beta sous_scores_faibles regle_appliquee]
  rows.each do |r|
    out << [r[:siren], r[:expected_label], r[:recent_score], r[:niveau_v1], r[:niveau_beta], r[:faibles], r[:regle_appliquee]]
  end
end
puts "→ #{OUTPUT_CSV}"

# ─── Métriques + IC Wilson 95 % ──────────────────────────────────────

def wilson(k, n)
  return [0.0, 0.0] if n == 0
  z = 1.96
  p = k.to_f / n
  denom = 1 + z**2 / n
  centre = (p + z**2 / (2 * n)) / denom
  spread = (z * Math.sqrt(p * (1 - p) / n + z**2 / (4 * n**2))) / denom
  [(centre - spread).clamp(0, 1), (centre + spread).clamp(0, 1)]
end

def metrics(rows, niveau_key, threshold_set)
  alert_levels = case threshold_set
  when :cde then %w[C D E]
  when :de  then %w[D E]
  end
  tp = fp = tn = fn = 0
  rows.each do |r|
    is_alert = alert_levels.include?(r[niveau_key])
    is_fragile = r[:expected_label] == 'fragile'
    if is_alert && is_fragile then tp += 1
    elsif is_alert && !is_fragile then fp += 1
    elsif !is_alert && is_fragile then fn += 1
    else tn += 1
    end
  end
  prec = (tp + fp) > 0 ? tp.to_f / (tp + fp) : 0.0
  rec  = (tp + fn) > 0 ? tp.to_f / (tp + fn) : 0.0
  f1   = (prec + rec) > 0 ? 2 * prec * rec / (prec + rec) : 0.0
  prec_ic = wilson(tp, tp + fp)
  rec_ic  = wilson(tp, tp + fn)
  { tp: tp, fp: fp, fn: fn, tn: tn, prec: prec, rec: rec, f1: f1, prec_ic: prec_ic, rec_ic: rec_ic }
end

puts ""
puts "═══ Distribution des changements de niveau ═══"
ch = Hash.new(0)
rows.each do |r|
  if r[:niveau_v1] != r[:niveau_beta]
    ch["#{r[:niveau_v1]}→#{r[:niveau_beta]}"] += 1
  end
end
puts "  Aucun changement : #{rows.count { |r| r[:niveau_v1] == r[:niveau_beta] }}/#{rows.size}"
ch.sort.each { |k, v| puts "  #{k} : #{v}" }

[:cde, :de].each do |th|
  v1   = metrics(rows, :niveau_v1, th)
  beta = metrics(rows, :niveau_beta, th)
  puts ""
  puts "═══ Seuil #{th.upcase.to_s} ═══"
  puts "  v1   : TP=#{v1[:tp]} FP=#{v1[:fp]} FN=#{v1[:fn]} TN=#{v1[:tn]}"
  puts "         prec=#{(v1[:prec]*100).round(1)}% [#{(v1[:prec_ic][0]*100).round(1)}–#{(v1[:prec_ic][1]*100).round(1)}%] rec=#{(v1[:rec]*100).round(1)}% [#{(v1[:rec_ic][0]*100).round(1)}–#{(v1[:rec_ic][1]*100).round(1)}%] f1=#{(v1[:f1]*100).round(1)}%"
  puts "  beta : TP=#{beta[:tp]} FP=#{beta[:fp]} FN=#{beta[:fn]} TN=#{beta[:tn]}"
  puts "         prec=#{(beta[:prec]*100).round(1)}% [#{(beta[:prec_ic][0]*100).round(1)}–#{(beta[:prec_ic][1]*100).round(1)}%] rec=#{(beta[:rec]*100).round(1)}% [#{(beta[:rec_ic][0]*100).round(1)}–#{(beta[:rec_ic][1]*100).round(1)}%] f1=#{(beta[:f1]*100).round(1)}%"
end

# ─── Détail des cas touchés par la règle ─────────────────────────────

puts ""
puts "═══ Cas touchés par la règle β (#{rows.count { |r| r[:regle_appliquee] }}) ═══"
rows.each do |r|
  next unless r[:regle_appliquee]
  pts = "rent=#{r[:detail]['rentabilite']} soli=#{r[:detail]['solidite']} liqu=#{r[:detail]['liquidite']} auto=#{r[:detail]['autonomie']} gouv=#{r[:detail]['gouvernance']}"
  marker = r[:expected_label] == 'fragile' ? '✓ TP' : '✗ FP'
  puts "  #{marker} | #{r[:siren]} #{r[:niveau_v1]}→#{r[:niveau_beta]} (#{r[:faibles]} faibles) | #{pts} | #{r[:title].to_s[0..60]}"
end
