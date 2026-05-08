#!/usr/bin/env ruby
# scripts/recompute_confusion_v2.rb
#
# Recalcule la matrice de confusion CRC en union v1 + v2.
#
# Sources :
#   - app/assets/fichiers_internes/data/phase4_results.csv     (v1, n=38, intact)
#   - app/assets/fichiers_internes/data/phase4_results_v2.csv  (v2, vague nouvelle)
#
# Métriques :
#   - Matrice 2×2 au seuil C/D/E (T_B=60) et au seuil D/E (T_C=40).
#   - Précision, rappel, F1.
#   - Intervalles de confiance Wilson 95 % sur précision et rappel.
#
# N'inclut dans la matrice que les SIREN à expected_label binaire (fragile/sain).

require 'csv'

PROJECT_ROOT = File.expand_path('..', __dir__)
DATA_DIR     = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data')
V1_CSV       = File.join(DATA_DIR, 'phase4_results.csv')
V2_CSV       = File.join(DATA_DIR, 'phase4_results_v2.csv')

# ─── Wilson 95 % CI for proportion ────────────────────────────────────

def wilson_ci(successes, total, z = 1.96)
  return [0.0, 0.0] if total.zero?
  p_hat   = successes.to_f / total
  denom   = 1.0 + (z**2) / total
  centre  = p_hat + (z**2) / (2 * total)
  margin  = z * Math.sqrt((p_hat * (1 - p_hat) + (z**2) / (4 * total)) / total)
  low     = (centre - margin) / denom
  high    = (centre + margin) / denom
  [[low, 0.0].max, [high, 1.0].min]
end

# ─── Chargement ───────────────────────────────────────────────────────

def load_rows(path)
  return [] unless File.exist?(path)
  rows = []
  CSV.foreach(path, headers: true) do |r|
    next unless %w[fragile sain].include?(r['expected_label'])
    next if r['recent_niveau'].to_s.empty?
    rows << {
      siren:           r['siren'],
      expected_label:  r['expected_label'],
      recent_niveau:   r['recent_niveau'],
      recent_score:    r['recent_score'].to_i
    }
  end
  rows
end

v1 = load_rows(V1_CSV)
v2 = load_rows(V2_CSV)

# Dédoublonnage (au cas improbable où un SIREN apparaît dans les deux)
seen = {}
combined = (v1 + v2).each do |r|
  seen[r[:siren]] ||= r
end
combined = seen.values

puts '═══ Recompute confusion CRC v2 ═══'
puts ''
puts "  v1 (phase4_results.csv)     : n=#{v1.size}  fragile=#{v1.count { |r| r[:expected_label] == 'fragile' }}  sain=#{v1.count { |r| r[:expected_label] == 'sain' }}"
puts "  v2 (phase4_results_v2.csv)  : n=#{v2.size}  fragile=#{v2.count { |r| r[:expected_label] == 'fragile' }}  sain=#{v2.count { |r| r[:expected_label] == 'sain' }}"
puts "  combiné dédoublonné         : n=#{combined.size}  fragile=#{combined.count { |r| r[:expected_label] == 'fragile' }}  sain=#{combined.count { |r| r[:expected_label] == 'sain' }}"
puts ''

# ─── Matrice à un seuil ───────────────────────────────────────────────

def matrix_at(rows, predicate_fragile)
  tp = fp = fn_ = tn = 0
  rows.each do |r|
    truth = r[:expected_label] == 'fragile'
    pred  = predicate_fragile.call(r)
    case [truth, pred]
    when [true,  true]  then tp += 1
    when [false, true]  then fp += 1
    when [true,  false] then fn_ += 1
    when [false, false] then tn += 1
    end
  end
  total     = tp + fp + fn_ + tn
  precision = (tp + fp).positive? ? tp.to_f / (tp + fp) : 0.0
  recall    = (tp + fn_).positive? ? tp.to_f / (tp + fn_) : 0.0
  f1        = (precision + recall).positive? ? 2 * precision * recall / (precision + recall) : 0.0

  prec_ci = wilson_ci(tp, tp + fp)
  rec_ci  = wilson_ci(tp, tp + fn_)
  { tp: tp, fp: fp, fn: fn_, tn: tn, total: total,
    precision: precision, recall: recall, f1: f1,
    prec_ci: prec_ci, rec_ci: rec_ci }
end

CDE = ->(r) { %w[C D E].include?(r[:recent_niveau]) }   # alerte (T_B=60)
DE  = ->(r) { %w[D E].include?(r[:recent_niveau]) }     # alerte forte (T_C=40)

def show(label, rows)
  return puts "  #{label}: n=0 — rien à calculer\n\n" if rows.empty?
  cde = matrix_at(rows, CDE)
  de  = matrix_at(rows, DE)
  puts "  ── #{label} (n=#{rows.size}) ──"
  [['Seuil C/D/E (T_B=60)', cde], ['Seuil D/E   (T_C=40)', de]].each do |name, m|
    pc_low, pc_high = m[:prec_ci]
    rc_low, rc_high = m[:rec_ci]
    puts "    #{name}"
    puts "      TP=#{m[:tp]}  FP=#{m[:fp]}  FN=#{m[:fn]}  TN=#{m[:tn]}"
    puts "      Précision : #{(m[:precision] * 100).round}%   IC95 [#{(pc_low * 100).round}%, #{(pc_high * 100).round}%]"
    puts "      Rappel    : #{(m[:recall] * 100).round}%   IC95 [#{(rc_low * 100).round}%, #{(rc_high * 100).round}%]"
    puts "      F1        : #{(m[:f1] * 100).round}%"
  end
  puts ''
  { cde: cde, de: de }
end

m_v1   = show('v1 seul',  v1)
m_v2   = show('v2 seul',  v2)
m_full = show('Combiné',  combined)

# ─── Comparaison ──────────────────────────────────────────────────────

if v1.any? && combined.any?
  puts '─── Comparaison v1 vs combiné ───'
  puts "  Δ n            : #{combined.size - v1.size} (de #{v1.size} à #{combined.size})"
  if m_v1 && m_full
    puts "  Δ précision C/D/E : #{((m_full[:cde][:precision] - m_v1[:cde][:precision]) * 100).round(1)} pt"
    puts "  Δ rappel    C/D/E : #{((m_full[:cde][:recall]    - m_v1[:cde][:recall])    * 100).round(1)} pt"
    puts "  Δ précision D/E   : #{((m_full[:de][:precision]  - m_v1[:de][:precision])  * 100).round(1)} pt"
    puts "  Δ rappel    D/E   : #{((m_full[:de][:recall]     - m_v1[:de][:recall])     * 100).round(1)} pt"
  end
end
