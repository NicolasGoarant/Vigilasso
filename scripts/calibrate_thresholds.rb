#!/usr/bin/env ruby
# scripts/calibrate_thresholds.rb
#
# Calibration empirique des seuils Vigil'Asso (A/B/C/D/E) à partir de :
#   - sample CRC : 38 cas (phase4_results.csv) avec label fragile/sain issu
#                  de l'audit Haiku des conclusions des chambres régionales
#   - sample BODACC : ~903 cas (data/scores_positifs.csv label=1 +
#                  data/scores_saines.csv label=0) avec label binaire issu
#                  de la présence ou non d'une procédure collective au BODACC
#
# Recherche par grille les seuils T_B et T_C qui maximisent la macro-F1
# définie comme moyenne de F1 aux deux opérationnels :
#   - alerte       : score < T_B   (= prédit "fragile" pour le seuil C/D/E)
#   - alerte forte : score < T_C   (= prédit "fragile" pour le seuil D/E)
#
# Note : T_A et T_D n'affectent aucune des métriques binaires (ils sont
# internes aux classes "sain" et "fragile"). On les propose en miroir des
# seuils actuels (T_A = T_B + 20, T_D = T_C - 20) pour préserver la largeur
# des paliers cosmétiques A/B et D/E.
#
# Lance via : ruby scripts/calibrate_thresholds.rb
# Pas d'écriture automatique de ScoringService — la décision revient à toi.

require 'csv'

PROJECT_ROOT = File.expand_path('..', __dir__)
PHASE4_CSV   = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data/phase4_results.csv')
POSITIFS_CSV = File.join(PROJECT_ROOT, 'data/scores_positifs.csv')
SAINES_CSV   = File.join(PROJECT_ROOT, 'data/scores_saines.csv')

CURRENT = { ta: 80, tb: 60, tc: 40, td: 20 }
STEP    = 2
TB_RANGE = (30..90).step(STEP).to_a
TC_RANGE = (10..70).step(STEP).to_a

# ─── Chargement ──────────────────────────────────────────────────────

def load_crc
  CSV.read(PHASE4_CSV, headers: true).map { |r|
    next nil if r['recent_score'].to_s.empty?
    {
      source: 'crc',
      siren:  r['siren'].to_s,
      score:  r['recent_score'].to_i,
      label:  r['expected_label'] == 'fragile' ? 1 : 0
    }
  }.compact
end

def load_bodacc
  rows = []
  CSV.foreach(POSITIFS_CSV, headers: true) do |r|
    next unless r['error'].to_s.empty? && !r['score'].to_s.empty?
    rows << { source: 'bodacc', siren: r['siren'].to_s, score: r['score'].to_i, label: 1 }
  end
  CSV.foreach(SAINES_CSV, headers: true) do |r|
    next unless r['error'].to_s.empty? && !r['score'].to_s.empty?
    rows << { source: 'bodacc', siren: r['siren'].to_s, score: r['score'].to_i, label: 0 }
  end
  rows
end

# ─── Métriques ───────────────────────────────────────────────────────

def confusion(samples, threshold)
  tp = fp = fn_ = tn = 0
  samples.each do |s|
    fragile_truth = s[:label] == 1
    fragile_pred  = s[:score] < threshold
    case [fragile_truth, fragile_pred]
    when [true,  true]  then tp  += 1
    when [false, true]  then fp  += 1
    when [true,  false] then fn_ += 1
    when [false, false] then tn  += 1
    end
  end
  precision = (tp + fp).positive? ? tp.to_f / (tp + fp) : 0.0
  recall    = (tp + fn_).positive? ? tp.to_f / (tp + fn_) : 0.0
  f1        = (precision + recall).positive? ? 2 * precision * recall / (precision + recall) : 0.0
  { tp: tp, fp: fp, fn: fn_, tn: tn, precision: precision, recall: recall, f1: f1 }
end

def metrics_at(samples, t_b, t_c)
  cde = confusion(samples, t_b)
  de  = confusion(samples, t_c)
  {
    cde:      cde,
    de:       de,
    macro_f1: (cde[:f1] + de[:f1]) / 2.0
  }
end

def fmt_metrics(m)
  "P=%-3d%% R=%-3d%% F1=%-3d%%" % [
    (m[:precision] * 100).round,
    (m[:recall]    * 100).round,
    (m[:f1]        * 100).round
  ]
end

# ─── Sortie console ──────────────────────────────────────────────────

def show_metrics(label, samples, t_b, t_c)
  m = metrics_at(samples, t_b, t_c)
  puts "  #{label.ljust(15)} (n=#{samples.size}, pos=#{samples.count { |s| s[:label] == 1 }}, neg=#{samples.count { |s| s[:label] == 0 }})"
  puts "    C/D/E (T_B=#{t_b}) : #{fmt_metrics(m[:cde])}  TP=#{m[:cde][:tp]} FP=#{m[:cde][:fp]} FN=#{m[:cde][:fn]} TN=#{m[:cde][:tn]}"
  puts "    D/E   (T_C=#{t_c}) : #{fmt_metrics(m[:de])}  TP=#{m[:de][:tp]} FP=#{m[:de][:fp]} FN=#{m[:de][:fn]} TN=#{m[:de][:tn]}"
  puts "    macro F1           : #{(m[:macro_f1] * 100).round(2)}%"
  m
end

# ─── Main ────────────────────────────────────────────────────────────

abort "#{PHASE4_CSV} introuvable."   unless File.exist?(PHASE4_CSV)
abort "#{POSITIFS_CSV} introuvable." unless File.exist?(POSITIFS_CSV)
abort "#{SAINES_CSV} introuvable."   unless File.exist?(SAINES_CSV)

crc    = load_crc
bodacc = load_bodacc
all    = crc + bodacc

puts '═══ Calibration v6 — sweep des seuils ═══'
puts ''
puts 'Composition des samples :'
puts "  CRC     : n=#{crc.size}    fragile=#{crc.count { |s| s[:label] == 1 }}  sain=#{crc.count { |s| s[:label] == 0 }}"
puts "  BODACC  : n=#{bodacc.size}    fragile=#{bodacc.count { |s| s[:label] == 1 }}  sain=#{bodacc.count { |s| s[:label] == 0 }}"
puts "  Combiné : n=#{all.size}    fragile=#{all.count { |s| s[:label] == 1 }}  sain=#{all.count { |s| s[:label] == 0 }}"
puts ''
puts '─── Métriques aux seuils actuels (T_A=80, T_B=60, T_C=40, T_D=20) ───'
puts ''
m_current_all    = show_metrics('combiné', all,    CURRENT[:tb], CURRENT[:tc])
puts ''
m_current_crc    = show_metrics('CRC seul', crc,    CURRENT[:tb], CURRENT[:tc])
puts ''
m_current_bodacc = show_metrics('BODACC seul', bodacc, CURRENT[:tb], CURRENT[:tc])
puts ''

# Sweep
puts '─── Sweep grille step=2 sur (T_B, T_C) avec T_B > T_C ───'
puts "  T_B ∈ [#{TB_RANGE.first}, #{TB_RANGE.last}]   T_C ∈ [#{TC_RANGE.first}, #{TC_RANGE.last}]"
puts ''

best       = nil
candidates = []
TB_RANGE.each do |t_b|
  TC_RANGE.each do |t_c|
    next if t_c >= t_b
    m = metrics_at(all, t_b, t_c)
    candidates << { t_b: t_b, t_c: t_c, m: m }
  end
end

# 1. macro F1 max
max_f1 = candidates.map { |c| c[:m][:macro_f1] }.max
top    = candidates.select { |c| (c[:m][:macro_f1] - max_f1).abs < 1e-9 }

# 2. tie-break = distance L1 aux seuils actuels
top.sort_by! { |c| (c[:t_b] - CURRENT[:tb]).abs + (c[:t_c] - CURRENT[:tc]).abs }
best = top.first

puts "  Évaluations testées : #{candidates.size}"
puts "  Macro-F1 maximale   : #{(max_f1 * 100).round(2)}%"
puts "  Optima ex æquo      : #{top.size}"
puts "  Choix retenu (le plus proche de l'actuel) : T_B=#{best[:t_b]}, T_C=#{best[:t_c]}"
puts ''

t_b_new = best[:t_b]
t_c_new = best[:t_c]
t_a_new = [t_b_new + 20, 100].min
t_d_new = [t_c_new - 20, 0].max

puts "Seuils complets proposés (T_A et T_D en miroir des deltas actuels) :"
puts "  T_A = #{t_a_new}   T_B = #{t_b_new}   T_C = #{t_c_new}   T_D = #{t_d_new}"
puts ''

puts '─── Métriques aux seuils proposés ───'
puts ''
m_new_all    = show_metrics('combiné',     all,    t_b_new, t_c_new)
puts ''
m_new_crc    = show_metrics('CRC seul',    crc,    t_b_new, t_c_new)
puts ''
m_new_bodacc = show_metrics('BODACC seul', bodacc, t_b_new, t_c_new)
puts ''

# ─── Top 5 candidats pour transparence ───

puts '─── Top 5 candidats (macro F1 décroissante, puis distance L1) ───'
ranked = candidates.sort_by { |c|
  [-c[:m][:macro_f1], (c[:t_b] - CURRENT[:tb]).abs + (c[:t_c] - CURRENT[:tc]).abs]
}.first(5)
ranked.each do |c|
  puts "  T_B=#{c[:t_b].to_s.rjust(2)} T_C=#{c[:t_c].to_s.rjust(2)} | macro F1=#{(c[:m][:macro_f1] * 100).round(2)}%  C/D/E F1=#{(c[:m][:cde][:f1] * 100).round}%  D/E F1=#{(c[:m][:de][:f1] * 100).round}%"
end
puts ''

# ─── Synthèse ───

delta_macro = ((best[:m][:macro_f1] - m_current_all[:macro_f1]) * 100).round(2)
delta_cde   = ((best[:m][:cde][:f1] - m_current_all[:cde][:f1]) * 100).round(1)
delta_de    = ((best[:m][:de][:f1]  - m_current_all[:de][:f1])  * 100).round(1)

puts '═══ Bilan ═══'
puts ''
puts "Gain macro F1 (combiné) : #{format('%+.2f', delta_macro)} pt"
puts "  ΔF1 C/D/E : #{format('%+.1f', delta_cde)} pt"
puts "  ΔF1 D/E   : #{format('%+.1f', delta_de)} pt"
puts ''
