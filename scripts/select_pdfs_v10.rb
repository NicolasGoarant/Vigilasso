#!/usr/bin/env ruby
# scripts/select_pdfs_v10.rb
#
# Sélectionne 400 PDFs (200 positifs + 200 saines) pour ré-extraction v10.
#
# Stratégie positifs :
#   - Source : ml/data/dataset_v9.csv (387 positifs)
#   - Filtre prioritaire : age_avant_jugement <= 3 ans (132 candidats)
#   - Fallback : si <200, complète par les plus récents (cloture desc)
# Stratégie saines :
#   - Source : ml/data/dataset_v9.csv (758 saines)
#   - Échantillon aléatoire 200 (srand(42))
#
# Résolution chemin PDF : data/pdfs_positifs/, data/pdfs_positifs_v8/,
#                         data/pdfs_saines/, tmp/jo_pdfs/ (dans cet ordre).
#
# Output : data/pdfs_sample_v10.csv (pdf_path, fichier, siren, cloture, label)

require 'csv'

PROJECT_ROOT = File.expand_path('..', __dir__)
DATASET_V9   = File.join(PROJECT_ROOT, 'ml/data/dataset_v9.csv')
OUTPUT_CSV   = File.join(PROJECT_ROOT, 'data/pdfs_sample_v10.csv')
N_POS        = 200
N_NEG        = 200

PDF_DIRS = [
  File.join(PROJECT_ROOT, 'data/pdfs_positifs'),
  File.join(PROJECT_ROOT, 'data/pdfs_positifs_v8'),
  File.join(PROJECT_ROOT, 'data/pdfs_saines'),
  File.join(PROJECT_ROOT, 'tmp/jo_pdfs')
].freeze

def resolve_pdf(fichier)
  PDF_DIRS.each do |dir|
    p = File.join(dir, fichier)
    return p if File.file?(p)
  end
  nil
end

abort "dataset_v9.csv introuvable" unless File.exist?(DATASET_V9)

rows = CSV.read(DATASET_V9, headers: true)
puts "[info] dataset_v9.csv : #{rows.size} lignes"

positifs = rows.select { |r| r['label'].to_i == 1 }
saines   = rows.select { |r| r['label'].to_i == 0 }
puts "[info]   positifs : #{positifs.size}"
puts "[info]   saines   : #{saines.size}"

# === Positifs ===
pos_with_age = positifs.select do |r|
  r['age_avant_jugement'] && !r['age_avant_jugement'].empty? && r['age_avant_jugement'].to_f <= 3.0
end
puts "[info]   positifs age<=3 : #{pos_with_age.size}"

if pos_with_age.size >= N_POS
  selected_pos = pos_with_age.sample(N_POS, random: Random.new(42))
  puts "[info]   sélection : 200 positifs age<=3 (échantillon aléatoire)"
else
  remaining = positifs - pos_with_age
  remaining_sorted = remaining.sort_by { |r| r['cloture'].to_s }.reverse
  fill = remaining_sorted.take(N_POS - pos_with_age.size)
  selected_pos = pos_with_age + fill
  puts "[info]   sélection : #{pos_with_age.size} age<=3 + #{fill.size} plus récents (fallback)"
end

# === Saines ===
selected_neg = saines.sample(N_NEG, random: Random.new(42))
puts "[info]   saines aléatoires : #{selected_neg.size}"

# === Résolution chemins ===
selected = selected_pos + selected_neg
unresolved = []
resolved_rows = []

selected.each do |r|
  fichier = r['fichier']
  path = resolve_pdf(fichier)
  if path.nil?
    unresolved << fichier
  else
    resolved_rows << {
      pdf_path: path,
      fichier:  fichier,
      siren:    r['siren'],
      cloture:  r['cloture'],
      label:    r['label']
    }
  end
end

puts "\n[info] PDFs résolus : #{resolved_rows.size}/#{selected.size}"
unless unresolved.empty?
  puts "[warn] #{unresolved.size} non-résolus (premier 5) :"
  unresolved.first(5).each { |f| puts "        #{f}" }
end

# === Distribution finale ===
n_pos_resolved = resolved_rows.count { |r| r[:label].to_i == 1 }
n_neg_resolved = resolved_rows.count { |r| r[:label].to_i == 0 }
puts "[info]   positifs résolus : #{n_pos_resolved}"
puts "[info]   saines résolues  : #{n_neg_resolved}"

# === Écriture ===
CSV.open(OUTPUT_CSV, 'wb') do |out|
  out << %w[pdf_path fichier siren cloture label]
  resolved_rows.each do |r|
    out << [r[:pdf_path], r[:fichier], r[:siren], r[:cloture], r[:label]]
  end
end
puts "\n[done] -> #{OUTPUT_CSV}"
