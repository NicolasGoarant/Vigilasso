#!/usr/bin/env ruby
# scripts/select_bodacc_sample_v11.rb
#
# Sélection stratifiée du sample BODACC v11 (phase 1 d'élargissement).
#
# Source     : bodacc_associations_enrichi.csv
# Exclusion  : SIREN ayant déjà ≥1 PDF dans
#                tmp/jo_pdfs/, data/pdfs_positifs/, data/pdfs_saines/,
#                data/pdfs_positifs_v8/
# Quotas (srand=42) :
#   - tous les jugements < 2022      (attendu 5)
#   - tous les jugements 2022        (attendu 22)
#   - 250 cas tirés en 2023
#   - 250 cas tirés en 2024
#   - 230 cas tirés en 2025
#   - tous les jugements 2026        (attendu 45)
#
# Output : data/bodacc_sample_v11.csv
#          (siren, date_jugement, nature_jugement, famille_jugement)

require 'csv'
require 'set'

PROJECT_ROOT = File.expand_path('..', __dir__)
INPUT_CSV    = File.join(PROJECT_ROOT, 'bodacc_associations_enrichi.csv')
OUTPUT_CSV   = File.join(PROJECT_ROOT, 'data/bodacc_sample_v11.csv')

PDF_DIRS = [
  File.join(PROJECT_ROOT, 'tmp/jo_pdfs'),
  File.join(PROJECT_ROOT, 'data/pdfs_positifs'),
  File.join(PROJECT_ROOT, 'data/pdfs_saines'),
  File.join(PROJECT_ROOT, 'data/pdfs_positifs_v8')
].freeze

QUOTAS = { '2023' => 250, '2024' => 250, '2025' => 230 }.freeze
RANDOM_SEED = 42

abort "#{INPUT_CSV} introuvable." unless File.exist?(INPUT_CSV)

# ─── Set des SIREN déjà couverts ─────────────────────────────────────

def existing_sirens
  set = Set.new
  PDF_DIRS.each do |dir|
    next unless Dir.exist?(dir)
    Dir.glob(File.join(dir, '*.pdf')).each do |path|
      bn = File.basename(path)
      set << $1 if bn =~ /\A(\d{9})_/
    end
  end
  set
end

covered = existing_sirens
puts '[Sample BODACC v11 — sélection stratifiée]'
puts "  SIREN déjà couverts (PDF présent) : #{covered.size}"
puts ''

# ─── Charge BODACC, dédup par SIREN, classe par année ────────────────

by_year = Hash.new { |h, k| h[k] = [] }
seen    = Set.new
total_input = 0
already_covered = 0
no_year         = 0

CSV.foreach(INPUT_CSV, headers: true) do |r|
  total_input += 1
  siren = r['siren'].to_s.strip
  next if siren.empty?
  next if seen.include?(siren)
  seen << siren

  if covered.include?(siren)
    already_covered += 1
    next
  end

  date = r['date_jugement'].to_s
  year = date =~ /\A(\d{4})/ ? $1 : nil
  if year.nil?
    no_year += 1
    next
  end

  by_year[year] << {
    siren:           siren,
    date_jugement:   date,
    nature_jugement: r['nature_jugement'],
    famille_jugement: r['famille_jugement']
  }
end

puts "  Lignes BODACC lues          : #{total_input}"
puts "  SIREN distincts             : #{seen.size}"
puts "  Exclus (déjà couverts)      : #{already_covered}"
puts "  Exclus (pas de date jugement): #{no_year}"
puts ''
puts '  Disponibles après exclusion :'
by_year.keys.sort.each do |y|
  puts "    #{y} : #{by_year[y].size}"
end
puts ''

# ─── Stratification ──────────────────────────────────────────────────

selected = []

# Tous les < 2022
years_avant_2022 = by_year.keys.select { |y| y.to_i < 2022 }
years_avant_2022.each { |y| selected.concat(by_year[y]) }

# Tous les 2022
selected.concat(by_year['2022']) if by_year.key?('2022')

# Sample par année 2023, 2024, 2025
srand(RANDOM_SEED)
QUOTAS.each do |year, n|
  pool = by_year[year] || []
  if pool.size <= n
    selected.concat(pool)
  else
    selected.concat(pool.sample(n))
  end
end

# Tous les 2026
selected.concat(by_year['2026']) if by_year.key?('2026')

# ─── Tri par date + siren pour reproductibilité ──────────────────────

selected.sort_by! { |r| [r[:date_jugement], r[:siren]] }

# ─── Composition finale ──────────────────────────────────────────────

puts '─── Composition finale du sample v11 ───'
final_by_year = Hash.new(0)
selected.each do |r|
  y = r[:date_jugement] =~ /\A(\d{4})/ ? $1 : '?'
  final_by_year[y] += 1
end
final_by_year.sort.each { |y, n| puts "    #{y} : #{n}" }
puts "    TOTAL : #{selected.size}"
puts ''

# ─── Écriture ────────────────────────────────────────────────────────

CSV.open(OUTPUT_CSV, 'wb') do |out|
  out << %w[siren date_jugement nature_jugement famille_jugement]
  selected.each do |r|
    out << [r[:siren], r[:date_jugement], r[:nature_jugement], r[:famille_jugement]]
  end
end

puts "  → #{OUTPUT_CSV}"
