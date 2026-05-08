#!/usr/bin/env ruby
# scripts/calibrate_thresholds_v11.rb
#
# Re-calibration des seuils Vigil'Asso (T_B, T_C) sur sample BODACC élargi v11.
#
# Sources des labels :
#   - CRC (n=38) : app/assets/fichiers_internes/data/phase4_results.csv
#       - score = recent_score
#       - label = expected_label == 'fragile' ? 1 : 0
#   - BODACC élargi : union dédoublonnée par fichier de
#       data/scores_positifs.csv      (label=1, source=positifs)
#       data/scores_positifs_v8.csv   (label=1, source=v8)
#       data/scores_positifs_v11.csv  (label=1, source=v11)
#       data/scores_saines.csv        (label=0, source=saines)
#
# Sweep grille (T_B, T_C) avec step=2, T_B > T_C, plage [20, 90].
# 4 variantes d'optimisation :
#   1. CRC seul
#   2. BODACC élargi seul
#   3. Combiné non-pondéré
#   4. Combiné équilibré 50/50 (F1 par source à poids égaux)
#
# Aucune écriture sur ScoringService. Output console + log
# /tmp/calibration_v11.log. Décision finale au utilisateur.

require 'csv'
require 'set'

PROJECT_ROOT = File.expand_path('..', __dir__)
PHASE4_CSV   = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data/phase4_results.csv')
POSITIFS_CSVS = {
  'positifs' => File.join(PROJECT_ROOT, 'data/scores_positifs.csv'),
  'v8'       => File.join(PROJECT_ROOT, 'data/scores_positifs_v8.csv'),
  'v11'      => File.join(PROJECT_ROOT, 'data/scores_positifs_v11.csv')
}.freeze
SAINES_CSV   = File.join(PROJECT_ROOT, 'data/scores_saines.csv')
LOG_PATH     = '/tmp/calibration_v11.log'

CURRENT  = { ta: 80, tb: 60, tc: 40, td: 20 }
STEP     = 2
TB_RANGE = (20..90).step(STEP).to_a
TC_RANGE = (20..90).step(STEP).to_a

LOG = File.open(LOG_PATH, 'w')
LOG.sync = true
def out(msg = '')
  puts msg
  LOG.puts msg
end

# ─── Chargement ──────────────────────────────────────────────────────

def load_crc(path)
  CSV.read(path, headers: true).map do |r|
    next nil if r['recent_score'].to_s.empty?
    {
      source: 'crc',
      key:    "crc:#{r['siren']}",
      siren:  r['siren'].to_s,
      score:  r['recent_score'].to_i,
      label:  r['expected_label'] == 'fragile' ? 1 : 0
    }
  end.compact
end

def read_bodacc_csv(path, source, label)
  rows = []
  CSV.foreach(path, headers: true) do |r|
    next unless r['error'].to_s.empty? && !r['score'].to_s.empty?
    rows << {
      source: source,
      key:    r['fichier'].to_s,
      siren:  r['siren'].to_s,
      score:  r['score'].to_i,
      label:  label
    }
  end
  rows
end

def load_bodacc(positifs_paths, saines_path)
  raw = []
  positifs_paths.each { |src, path| raw.concat(read_bodacc_csv(path, src, 1)) }
  raw.concat(read_bodacc_csv(saines_path, 'saines', 0))

  # ─── Dédoublonnage par fichier ────────────────────────────────────
  seen      = {}
  conflicts = []
  raw.each do |r|
    if seen.key?(r[:key])
      prev = seen[r[:key]]
      if prev[:label] != r[:label]
        conflicts << { key: r[:key], existing: prev[:source], duplicate: r[:source] }
        # On garde le label=1 si conflit positifs/saines
        seen[r[:key]] = r if r[:label] == 1 && prev[:label] == 0
      end
      # même label → on garde la première occurrence
    else
      seen[r[:key]] = r
    end
  end
  [seen.values, raw.size, conflicts]
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
  { cde: cde, de: de, macro_f1: (cde[:f1] + de[:f1]) / 2.0 }
end

# Combiné équilibré 50/50 : moyenne des macro-F1 par source.
def metrics_balanced(crc, bodacc, t_b, t_c)
  m_c = metrics_at(crc, t_b, t_c)
  m_b = metrics_at(bodacc, t_b, t_c)
  {
    cde:      { f1: (m_c[:cde][:f1] + m_b[:cde][:f1]) / 2.0 },
    de:       { f1: (m_c[:de][:f1]  + m_b[:de][:f1])  / 2.0 },
    macro_f1: (m_c[:macro_f1] + m_b[:macro_f1]) / 2.0
  }
end

def fmt_metrics(m)
  "P=%-3d%% R=%-3d%% F1=%-3d%%" % [
    (m[:precision] * 100).round,
    (m[:recall]    * 100).round,
    (m[:f1]        * 100).round
  ]
end

def show_metrics(label, samples, t_b, t_c)
  m = metrics_at(samples, t_b, t_c)
  out "  #{label.ljust(20)} (n=#{samples.size}, pos=#{samples.count { |s| s[:label] == 1 }}, neg=#{samples.count { |s| s[:label] == 0 }})"
  out "    C/D/E (T_B=#{t_b}) : #{fmt_metrics(m[:cde])}  TP=#{m[:cde][:tp]} FP=#{m[:cde][:fp]} FN=#{m[:cde][:fn]} TN=#{m[:cde][:tn]}"
  out "    D/E   (T_C=#{t_c}) : #{fmt_metrics(m[:de])}  TP=#{m[:de][:tp]} FP=#{m[:de][:fp]} FN=#{m[:de][:fn]} TN=#{m[:de][:tn]}"
  out "    macro F1            : #{(m[:macro_f1] * 100).round(2)}%"
  m
end

def show_balanced(label, crc, bodacc, t_b, t_c)
  m = metrics_balanced(crc, bodacc, t_b, t_c)
  out "  #{label.ljust(20)} (CRC + BODACC, poids 50/50)"
  out "    C/D/E (T_B=#{t_b}) : F1=#{(m[:cde][:f1] * 100).round}%"
  out "    D/E   (T_C=#{t_c}) : F1=#{(m[:de][:f1]  * 100).round}%"
  out "    macro F1            : #{(m[:macro_f1] * 100).round(2)}%"
  m
end

# ─── Optimisation ────────────────────────────────────────────────────

def sweep(scoring_fn)
  best = nil
  candidates = []
  TB_RANGE.each do |t_b|
    TC_RANGE.each do |t_c|
      next if t_c >= t_b
      m = scoring_fn.call(t_b, t_c)
      candidates << { t_b: t_b, t_c: t_c, m: m }
    end
  end
  max_f1 = candidates.map { |c| c[:m][:macro_f1] }.max
  top    = candidates.select { |c| (c[:m][:macro_f1] - max_f1).abs < 1e-9 }
  top.sort_by! { |c| (c[:t_b] - CURRENT[:tb]).abs + (c[:t_c] - CURRENT[:tc]).abs }
  best = top.first
  [best, candidates, max_f1, top.size]
end

# ─── Main ────────────────────────────────────────────────────────────

[PHASE4_CSV, SAINES_CSV].each { |p| abort "#{p} introuvable." unless File.exist?(p) }
POSITIFS_CSVS.each_value { |p| abort "#{p} introuvable." unless File.exist?(p) }

crc = load_crc(PHASE4_CSV)
bodacc, raw_bodacc_count, conflicts = load_bodacc(POSITIFS_CSVS, SAINES_CSV)

out '═══ Calibration v11 — sweep des seuils sur dataset élargi ═══'
out ''
out 'Composition des samples :'
out "  CRC                 : n=#{crc.size}    fragile=#{crc.count { |s| s[:label] == 1 }}  sain=#{crc.count { |s| s[:label] == 0 }}"
out ''
out '  BODACC sources brutes :'
out "    positifs (avant v8) : #{bodacc.count { |s| s[:source] == 'positifs' }}"
out "    v8                  : #{bodacc.count { |s| s[:source] == 'v8' }}"
out "    v11                 : #{bodacc.count { |s| s[:source] == 'v11' }}"
out "    saines              : #{bodacc.count { |s| s[:source] == 'saines' }}"
out ''
out "  BODACC dédoublonné  : n=#{bodacc.size}    fragile=#{bodacc.count { |s| s[:label] == 1 }}  sain=#{bodacc.count { |s| s[:label] == 0 }}"
out "    (lignes brutes : #{raw_bodacc_count}, doublons éliminés : #{raw_bodacc_count - bodacc.size})"
unless conflicts.empty?
  out "  ⚠ Conflits label positifs↔saines : #{conflicts.size}"
  conflicts.first(5).each { |c| out "      #{c[:key]} : #{c[:existing]} ↔ #{c[:duplicate]}" }
end
combined = crc + bodacc
out ''
out "  Combiné             : n=#{combined.size}    fragile=#{combined.count { |s| s[:label] == 1 }}  sain=#{combined.count { |s| s[:label] == 0 }}"

# ─── Métriques aux seuils actuels ────────────────────────────────────

out ''
out '─── Métriques aux seuils actuels (T_A=80, T_B=60, T_C=40, T_D=20) ───'
out ''
m_cur_crc      = show_metrics('CRC',           crc,    CURRENT[:tb], CURRENT[:tc])
out ''
m_cur_bodacc   = show_metrics('BODACC élargi', bodacc, CURRENT[:tb], CURRENT[:tc])
out ''
m_cur_combo    = show_metrics('Combiné brut',  combined, CURRENT[:tb], CURRENT[:tc])
out ''
m_cur_balanced = show_balanced('Combiné 50/50', crc, bodacc, CURRENT[:tb], CURRENT[:tc])

# ─── Sweep par variante ──────────────────────────────────────────────

out ''
out '─── Sweep grille (T_B, T_C) step=2, T_B > T_C, [20, 90] ───'

variants = {
  'CRC seul'         => ->(tb, tc) { metrics_at(crc, tb, tc) },
  'BODACC élargi'    => ->(tb, tc) { metrics_at(bodacc, tb, tc) },
  'Combiné brut'     => ->(tb, tc) { metrics_at(combined, tb, tc) },
  'Combiné 50/50'    => ->(tb, tc) { metrics_balanced(crc, bodacc, tb, tc) }
}

results = {}
variants.each do |name, fn|
  best, candidates, max_f1, ties = sweep(fn)
  results[name] = { best: best, candidates: candidates, max_f1: max_f1, ties: ties }
  out ''
  out "▶ Optimum #{name}"
  out "    Évaluations         : #{candidates.size}"
  out "    Macro-F1 max        : #{(max_f1 * 100).round(2)}%"
  out "    Ex æquo             : #{ties}"
  out "    Choix proche actuel : T_B=#{best[:t_b]}, T_C=#{best[:t_c]}"
  out "    Macro F1 cur (#{CURRENT[:tb]}/#{CURRENT[:tc]}) : #{(fn.call(CURRENT[:tb], CURRENT[:tc])[:macro_f1] * 100).round(2)}%"
  out "    Δ macro F1          : +#{((max_f1 - fn.call(CURRENT[:tb], CURRENT[:tc])[:macro_f1]) * 100).round(2)} pt"
end

# ─── Top 5 par variante ──────────────────────────────────────────────

out ''
out '─── Top 5 candidats par variante ───'
variants.each do |name, _fn|
  out ''
  out "  #{name} :"
  ranked = results[name][:candidates].sort_by { |c|
    [-c[:m][:macro_f1], (c[:t_b] - CURRENT[:tb]).abs + (c[:t_c] - CURRENT[:tc]).abs]
  }.first(5)
  ranked.each do |c|
    cde_f1 = (c[:m][:cde][:f1] * 100).round
    de_f1  = (c[:m][:de][:f1]  * 100).round
    out "    T_B=#{c[:t_b].to_s.rjust(2)} T_C=#{c[:t_c].to_s.rjust(2)} | macro F1=#{(c[:m][:macro_f1] * 100).round(2)}%  C/D/E F1=#{cde_f1}%  D/E F1=#{de_f1}%"
  end
end

# ─── Métriques aux seuils proposés (variante équilibrée — recommandée) ─

out ''
out '─── Détail aux seuils optima de chaque variante ───'
variants.each do |name, _fn|
  best = results[name][:best]
  out ''
  out "▶ #{name} → T_B=#{best[:t_b]}, T_C=#{best[:t_c]}"
  show_metrics('  CRC',           crc,    best[:t_b], best[:t_c])
  show_metrics('  BODACC élargi', bodacc, best[:t_b], best[:t_c])
  show_balanced('  Combiné 50/50', crc, bodacc, best[:t_b], best[:t_c])
end

out ''
out '═══ Bilan ═══'
out ''
out "Seuils actuels : T_A=#{CURRENT[:ta]}, T_B=#{CURRENT[:tb]}, T_C=#{CURRENT[:tc]}, T_D=#{CURRENT[:td]}"
out ''
variants.each do |name, _fn|
  best = results[name][:best]
  out "  Optimum #{name.ljust(15)} : T_B=#{best[:t_b].to_s.rjust(2)}  T_C=#{best[:t_c].to_s.rjust(2)}  macro F1=#{(results[name][:max_f1] * 100).round(2)}%"
end
out ''
out "  Log complet : #{LOG_PATH}"
