#!/usr/bin/env ruby
# scripts/identify_lost_sirens.rb
#
# Identifie les SIREN « perdus » entre la phase 2-3 (vérification SIREN +
# audit qualitatif des conclusions CRC) et la phase 4 (scoring Vigil'Asso).
#
# Source           : sirens_verified.csv (115 SIREN distincts)
# Exclus           : SIREN déjà scorés dans phase4_results.csv
# Exclus aussi    : SIREN dont au moins un PDF JOAFE est déjà sur disque
#                   (tmp/jo_pdfs/, data/pdfs_positifs/, data/pdfs_saines/,
#                    data/pdfs_positifs_v8/, data/pdfs_positifs_v11/)
#
# Pour chaque SIREN restant, on récupère expected_label et synthese_crc
# par jointure sur audit_pdfs.csv :
#   - primary == 'fragilite_financiere' → expected_label = 'fragile'
#   - primary == 'rien_critique'        → expected_label = 'sain'
#   - autre                             → expected_label = nil (non-binaire,
#                                          exclus du calcul de la matrice CRC)
#
# Output : app/assets/fichiers_internes/data/sirens_to_scrape_phase4_v2.csv
#          colonnes : siren, nom, expected_label, synthese_crc, audit_primary,
#                     title, url

require 'csv'
require 'set'

PROJECT_ROOT  = File.expand_path('..', __dir__)
DATA_DIR      = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data')
VERIFIED_CSV  = File.join(DATA_DIR, 'sirens_verified.csv')
AUDIT_CSV     = File.join(DATA_DIR, 'audit_pdfs.csv')
PHASE4_CSV    = File.join(DATA_DIR, 'phase4_results.csv')
OUTPUT_CSV    = File.join(DATA_DIR, 'sirens_to_scrape_phase4_v2.csv')

PDF_DIRS = %w[
  tmp/jo_pdfs
  data/pdfs_positifs
  data/pdfs_saines
  data/pdfs_positifs_v8
  data/pdfs_positifs_v11
].map { |d| File.join(PROJECT_ROOT, d) }.freeze

[VERIFIED_CSV, AUDIT_CSV, PHASE4_CSV].each do |p|
  abort "#{p} introuvable." unless File.exist?(p)
end

# ─── Index audit_pdfs.csv ────────────────────────────────────────────

audit = {}
CSV.foreach(AUDIT_CSV, headers: true) do |r|
  s = r['siren'].to_s.strip
  next if s.empty?
  audit[s] ||= {
    primary: r['primary'].to_s,
    synthese: r['synthese'].to_s,
    title: r['title'].to_s
  }
end

def expected_label_from_primary(primary)
  case primary
  when 'fragilite_financiere' then 'fragile'
  when 'rien_critique'        then 'sain'
  else                             nil
  end
end

# ─── Set des SIREN déjà scorés en phase 4 ────────────────────────────

scored = Set.new
CSV.foreach(PHASE4_CSV, headers: true) { |r| scored << r['siren'] if r['siren'] }

# ─── Set des SIREN ayant déjà un PDF local ───────────────────────────

covered = Set.new
PDF_DIRS.each do |dir|
  next unless Dir.exist?(dir)
  Dir.glob(File.join(dir, '*.pdf')).each do |path|
    bn = File.basename(path)
    covered << $1 if bn =~ /\A(\d{9})_/
  end
end

# ─── Sélection ───────────────────────────────────────────────────────

verified = {}
CSV.foreach(VERIFIED_CSV, headers: true) do |r|
  s = r['siren'].to_s.strip
  next if s.empty?
  verified[s] ||= {
    url: r['url'].to_s,
    title: r['title'].to_s,
    canonical_name: r['canonical_name'].to_s
  }
end

candidates = []
verified.each do |siren, vrow|
  next if scored.include?(siren)
  next if covered.include?(siren)

  arow = audit[siren] || {}
  candidates << {
    siren:           siren,
    nom:             vrow[:canonical_name],
    expected_label:  expected_label_from_primary(arow[:primary]),
    audit_primary:   arow[:primary],
    synthese_crc:    arow[:synthese],
    title:           vrow[:title].empty? ? arow[:title] : vrow[:title],
    url:             vrow[:url]
  }
end

# Tri stable : binaires en tête (utiles pour la matrice), puis le reste
candidates.sort_by! do |c|
  bucket = case c[:expected_label]
           when 'fragile' then 0
           when 'sain'    then 1
           else                2
           end
  [bucket, c[:siren]]
end

# ─── Diagnostic ──────────────────────────────────────────────────────

puts '[Identify lost SIREN — phase 4 v2]'
puts ''
puts "  sirens_verified.csv distincts        : #{verified.size}"
puts "  phase4_results.csv distincts         : #{scored.size}"
puts "  PDFs locaux (5 dossiers, distincts)  : #{covered.size}"
puts ''
puts "  Candidats à scraper (lost ∧ ¬covered) : #{candidates.size}"
puts ''
dist = Hash.new(0)
candidates.each { |c| dist[c[:audit_primary].to_s.empty? ? '(absent audit)' : c[:audit_primary]] += 1 }
puts '  Distribution audit_primary :'
dist.sort_by { |_, n| -n }.each { |k, n| puts "    #{k.ljust(40)} #{n}" }
puts ''
binary  = candidates.count { |c| c[:expected_label] }
puts "  → SIREN à label binaire utilisables  : #{binary}"
puts "  → SIREN à label non-binaire (scorés mais hors matrice) : #{candidates.size - binary}"

# ─── Écriture ────────────────────────────────────────────────────────

CSV.open(OUTPUT_CSV, 'wb') do |out|
  out << %w[siren nom expected_label synthese_crc audit_primary title url]
  candidates.each do |c|
    out << [c[:siren], c[:nom], c[:expected_label], c[:synthese_crc],
            c[:audit_primary], c[:title], c[:url]]
  end
end

puts ''
puts "  → #{OUTPUT_CSV}"
