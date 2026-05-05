#!/usr/bin/env ruby
# scripts/build_phase3_csv.rb
#
# Régénère sirens_for_phase3.csv en croisant audit_pdfs.csv + reports.csv,
# en ajoutant pub_date (date de publication du rapport CRC) et
# years_since_report (âge du rapport en années).
#
# Trie par pub_date décroissante (plus récent en premier) pour que tu puisses
# filtrer facilement par récence.
#
# Affiche aussi une répartition par âge pour voir combien de cas restent
# si tu filtres à ≤ 3 ans, ≤ 5 ans, etc.

require 'csv'
require 'date'

PROJECT_ROOT  = File.expand_path('..', __dir__)
DATA_DIR      = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data')
REPORTS_CSV   = File.join(DATA_DIR, 'reports.csv')
AUDIT_CSV     = File.join(DATA_DIR, 'audit_pdfs.csv')
PHASE3_CSV    = File.join(DATA_DIR, 'sirens_for_phase3.csv')

abort "#{REPORTS_CSV} introuvable." unless File.exist?(REPORTS_CSV)
abort "#{AUDIT_CSV} introuvable. Lance d'abord audit_pdfs.rb all." unless File.exist?(AUDIT_CSV)

# url → pub_date depuis reports.csv
pub_date_by_url = {}
CSV.foreach(REPORTS_CSV, headers: true) do |r|
  pub_date_by_url[r['url']] = r['pub_date']
end

today = Date.today

def parse_date(s)
  Date.parse(s.to_s)
rescue StandardError
  nil
end

# Filtre les cas exploitables (fragile + sain) avec SIREN identifié
rows = CSV.read(AUDIT_CSV, headers: true)
exploitables = rows.select { |r|
  %w[fragilite_financiere rien_critique].include?(r['primary']) &&
    !r['siren'].to_s.empty?
}.map { |r|
  pd = pub_date_by_url[r['url']]
  d  = parse_date(pd)
  years = d ? ((today - d).to_f / 365.25).round(1) : nil
  {
    siren:          r['siren'],
    expected_label: r['primary'] == 'fragilite_financiere' ? 'fragile' : 'sain',
    title:          r['title'],
    pub_date:       pd,
    years:          years,
    url:            r['url'],
    synthese:       r['synthese']
  }
}

# Tri : plus récents en premier (nil en dernier)
exploitables.sort_by! { |e| [e[:years].nil? ? 1 : 0, e[:years] || 99.0] }

CSV.open(PHASE3_CSV, 'wb') do |out|
  out << %w[siren expected_label title pub_date years_since_report url synthese]
  exploitables.each do |e|
    out << [e[:siren], e[:expected_label], e[:title],
            e[:pub_date], e[:years], e[:url], e[:synthese]]
  end
end

puts "  → #{PHASE3_CSV}"
puts ''

# Répartition par âge
buckets = {
  '≤ 1 an'    => ->(y) { y && y <= 1.0 },
  '1 - 3 ans' => ->(y) { y && y > 1.0 && y <= 3.0 },
  '3 - 5 ans' => ->(y) { y && y > 3.0 && y <= 5.0 },
  '5 - 8 ans' => ->(y) { y && y > 5.0 && y <= 8.0 },
  '> 8 ans'   => ->(y) { y && y > 8.0 },
  'date inconnue' => ->(y) { y.nil? }
}

puts '═══ Répartition par âge du rapport ═══'
puts ''
puts "Total exploitables : #{exploitables.size}"
puts ''
buckets.each do |label, pred|
  matched = exploitables.select { |e| pred.call(e[:years]) }
  pos = matched.count { |e| e[:expected_label] == 'fragile' }
  neg = matched.count { |e| e[:expected_label] == 'sain' }
  bar = '█' * (matched.size.to_f / exploitables.size * 30).round
  puts "  #{label.ljust(15)} #{matched.size.to_s.rjust(2)} (#{pos} fragile + #{neg} sain)  #{bar}"
end

# Suggestions de sous-échantillon par seuil
puts ''
puts '═══ Sous-échantillons par seuil de récence ═══'
puts ''
[3.0, 5.0, 8.0].each do |threshold|
  sub = exploitables.select { |e| e[:years] && e[:years] <= threshold }
  pos = sub.count { |e| e[:expected_label] == 'fragile' }
  neg = sub.count { |e| e[:expected_label] == 'sain' }
  puts "  ≤ #{threshold} ans : #{sub.size} cas (#{pos} fragile + #{neg} sain)"
end

# Top 10 plus récents pour aperçu
puts ''
puts '═══ 10 rapports les plus récents ═══'
puts ''
exploitables.first(10).each do |e|
  age = e[:years] ? "#{e[:years]} ans".rjust(8) : 'date ??'.rjust(8)
  label = e[:expected_label].ljust(7)
  puts "  #{e[:siren]}  #{age}  #{label}  #{e[:title].slice(0, 55)}"
end
