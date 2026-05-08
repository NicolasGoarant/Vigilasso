#!/usr/bin/env ruby
# scripts/analyze_alpha_fp.rb
#
# Joint scores_alpha.csv avec phase4_results.csv et compare la
# distribution des deux nouvelles features (fonds_dedies_pct et
# secteur_atypique) entre faux positifs (FP) et vrais positifs (TP)
# du sample CRC n=38.
#
# Lance via : ruby scripts/analyze_alpha_fp.rb

require 'csv'

PROJECT_ROOT = File.expand_path('..', __dir__)
PHASE4 = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data/phase4_results.csv')
ALPHA  = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data/scores_alpha.csv')

abort "#{ALPHA} introuvable. Lance d'abord extract_alpha.rb." unless File.exist?(ALPHA)

phase4 = {}
CSV.foreach(PHASE4, headers: true) { |r| phase4[r['siren']] = r }

alpha = {}
CSV.foreach(ALPHA, headers: true) do |r|
  next if r['error'] && !r['error'].to_s.empty?
  alpha[r['siren']] = r
end

joined = []
phase4.each do |siren, p|
  a = alpha[siren]
  next unless a
  vigi_alert = %w[C D E].include?(p['recent_niveau'].to_s)
  fragile    = p['expected_label'].to_s.downcase == 'fragile'
  next unless vigi_alert
  group = fragile ? :tp : :fp
  joined << {
    siren: siren,
    group: group,
    title: p['title'],
    niveau: p['recent_niveau'],
    fonds_dedies_pct: a['fonds_dedies_pct'].to_s.empty? ? nil : a['fonds_dedies_pct'].to_f,
    secteur: a['secteur_atypique'],
    secteur_just: a['secteur_atypique_justification']
  }
end

tp = joined.select { |r| r[:group] == :tp }
fp = joined.select { |r| r[:group] == :fp }
puts "Joint : #{joined.size} cas (FP=#{fp.size}, TP=#{tp.size})"

def stats(values)
  vals = values.compact.sort
  return { n: values.size, n_present: 0, n_null: values.size } if vals.empty?
  q = ->(p) { vals[(vals.size * p).floor.clamp(0, vals.size - 1)] }
  {
    n: values.size, n_present: vals.size, n_null: values.size - vals.size,
    min: vals.first, max: vals.last,
    median: q.call(0.5), q1: q.call(0.25), q3: q.call(0.75)
  }
end

# ─── Stat 1 : fonds_dedies_pct ──────────────────────────────────────

puts ""
puts "═══ fonds_dedies_pct ═══"
fp_fd = fp.map { |r| r[:fonds_dedies_pct] }
tp_fd = tp.map { |r| r[:fonds_dedies_pct] }
sfp = stats(fp_fd); stp = stats(tp_fd)
[[:fp, sfp], [:tp, stp]].each do |g, s|
  if s[:n_present] == 0
    puts "  #{g.upcase} (n=#{s[:n]}) : tous null (n_null=#{s[:n_null]})"
  else
    puts "  #{g.upcase} (n=#{s[:n]}) : présents=#{s[:n_present]}, null=#{s[:n_null]}"
    puts "    min=#{s[:min].round(3)} q1=#{s[:q1].round(3)} median=#{s[:median].round(3)} q3=#{s[:q3].round(3)} max=#{s[:max].round(3)}"
  end
end

# Mann-Whitney U (n petits, calcul direct)
def mann_whitney(x, y)
  return nil if x.empty? || y.empty?
  combined = x.map { |v| [v, :x] } + y.map { |v| [v, :y] }
  combined.sort_by! { |v, _| v }
  ranks = {}
  combined.each_with_index do |(v, _), i|
    (ranks[v] ||= []) << (i + 1)
  end
  combined.each_with_index do |(v, src), i|
    avg_rank = ranks[v].sum.to_f / ranks[v].size
    combined[i] = [v, src, avg_rank]
  end
  rx = combined.select { |_, s, _| s == :x }.sum { |_, _, r| r }
  nx = x.size; ny = y.size
  u1 = rx - nx * (nx + 1) / 2.0
  u2 = nx * ny - u1
  { u: [u1, u2].min, u1: u1, u2: u2, nx: nx, ny: ny }
end

mw = mann_whitney(fp_fd.compact, tp_fd.compact)
if mw
  puts ""
  puts "  Mann-Whitney U (présents seulement) :"
  puts "    n_FP=#{mw[:nx]} n_TP=#{mw[:ny]} U_min=#{mw[:u]} (U max théorique = #{mw[:nx] * mw[:ny]})"
  ratio = mw[:u].to_f / (mw[:nx] * mw[:ny])
  puts "    Ratio U/max = #{ratio.round(3)} (0.5 = pas de séparation, 0 ou 1 = séparation totale)"
else
  puts "  Mann-Whitney non calculable (pas assez de données)"
end

# Cliff's delta (effect size, indépendant de la distribution)
def cliffs_delta(x, y)
  return nil if x.empty? || y.empty?
  pairs = x.size * y.size
  diff = 0
  x.each do |xv|
    y.each do |yv|
      diff += 1 if xv > yv
      diff -= 1 if xv < yv
    end
  end
  diff.to_f / pairs
end

cd = cliffs_delta(fp_fd.compact, tp_fd.compact)
puts "  Cliff's delta (FP vs TP) = #{cd ? cd.round(3) : 'n/a'}  (|δ| < 0.147 = négligeable, < 0.33 = petit, < 0.474 = moyen, sinon grand)"

# ─── Stat 2 : secteur_atypique ──────────────────────────────────────

puts ""
puts "═══ secteur_atypique ═══"
secteurs = (fp + tp).map { |r| r[:secteur] }.uniq
puts "  catégories rencontrées : #{secteurs.compact.inspect}#{secteurs.include?(nil) ? ' + null' : ''}"

table = Hash.new { |h, k| h[k] = { fp: 0, tp: 0 } }
fp.each { |r| table[r[:secteur] || '(null)'][:fp] += 1 }
tp.each { |r| table[r[:secteur] || '(null)'][:tp] += 1 }
puts "  | secteur               | FP | TP |"
puts "  |-----------------------|---:|---:|"
table.sort.each { |k, v| puts "  | #{k.to_s.ljust(21)} | #{v[:fp].to_s.rjust(2)} | #{v[:tp].to_s.rjust(2)} |" }

# Atypique vs standard
fp_atyp = fp.count { |r| r[:secteur] && r[:secteur] != 'standard' }
tp_atyp = tp.count { |r| r[:secteur] && r[:secteur] != 'standard' }
puts ""
puts "  Atypique (≠ standard) : FP=#{fp_atyp}/#{fp.size} (#{(100.0*fp_atyp/fp.size).round(1)}%), TP=#{tp_atyp}/#{tp.size} (#{(100.0*tp_atyp/tp.size).round(1)}%)"

# Test de Fisher exact 2x2 (atypique vs standard) × (FP vs TP)
def fisher_2x2(a, b, c, d)
  # Probabilité exacte d'observer la table {{a,b},{c,d}} ou plus extrême,
  # par sommation des hypergéométriques.
  n = a + b + c + d
  r1 = a + b
  c1 = a + c
  log_fact = Array.new(n + 1, 0.0)
  (1..n).each { |i| log_fact[i] = log_fact[i - 1] + Math.log(i) }
  prob = ->(k) {
    Math.exp(log_fact[r1] + log_fact[n - r1] + log_fact[c1] + log_fact[n - c1] - log_fact[n] - log_fact[k] - log_fact[r1 - k] - log_fact[c1 - k] - log_fact[n - r1 - c1 + k])
  }
  observed = prob.call(a)
  k_min = [0, c1 - (n - r1)].max
  k_max = [r1, c1].min
  p_two_tailed = (k_min..k_max).sum { |k| pk = prob.call(k); pk <= observed + 1e-12 ? pk : 0.0 }
  p_two_tailed.clamp(0, 1)
end

fp_std = fp.size - fp_atyp
tp_std = tp.size - tp_atyp
p = fisher_2x2(fp_atyp, fp_std, tp_atyp, tp_std)
puts "  Fisher exact 2-sided (atypique × FP) : p = #{p.round(4)}"

# ─── Listing détaillé ────────────────────────────────────────────────

puts ""
puts "═══ Détail FP (n=#{fp.size}) ═══"
fp.each do |r|
  fd = r[:fonds_dedies_pct] ? r[:fonds_dedies_pct].round(3) : 'null'
  puts "  #{r[:siren]} #{r[:niveau]} | fd=#{fd} sect=#{r[:secteur]} | #{r[:title].to_s[0..60]}"
end

puts ""
puts "═══ Détail TP (n=#{tp.size}) ═══"
tp.each do |r|
  fd = r[:fonds_dedies_pct] ? r[:fonds_dedies_pct].round(3) : 'null'
  puts "  #{r[:siren]} #{r[:niveau]} | fd=#{fd} sect=#{r[:secteur]} | #{r[:title].to_s[0..60]}"
end
