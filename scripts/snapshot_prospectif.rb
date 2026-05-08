#!/usr/bin/env ruby
# scripts/snapshot_prospectif.rb
#
# Fige l'état de scoring courant de toutes les associations en DB pour
# permettre, dans 12-24 mois, une mesure de validation prospective :
# comparer les niveaux Vigil'Asso à T0 avec les jugements BODACC publiés
# entre T0 et T1.
#
# Lance via : bundle exec rails runner scripts/snapshot_prospectif.rb
#
# Output : data/snapshot_prospectif_<YYYY-MM-DD>.csv (date du jour)
#
# Champs CSV :
#   siren, cloture, nom, ville, departement, ape_section,
#   score_vigi, niveau_vigi,
#   pts_rent, pts_soli, pts_liqu, pts_auto, pts_gouv,
#   date_snapshot
#
# departement et ape_section sont joints sur bodacc_associations_enrichi.csv
# (via SIREN) ; null si l'asso n'est pas dans ce CSV (= sample saines).

require 'csv'
require 'date'

PROJECT_ROOT = File.expand_path('..', __dir__)
BODACC_CSV   = File.join(PROJECT_ROOT, 'bodacc_associations_enrichi.csv')

DATE_SNAPSHOT = Date.today.iso8601
OUTPUT_CSV    = File.join(PROJECT_ROOT, "data/snapshot_prospectif_#{DATE_SNAPSHOT}.csv")

CSV_HEADERS = %w[
  siren cloture nom ville departement ape_section
  score_vigi niveau_vigi
  pts_rent pts_soli pts_liqu pts_auto pts_gouv
  date_snapshot
].freeze

# ─── Index BODACC (siren → departement + ape_section) ────────────────

bodacc_index = {}
if File.exist?(BODACC_CSV)
  CSV.foreach(BODACC_CSV, headers: true) do |r|
    s = r['siren'].to_s.strip
    next if s.empty? || bodacc_index.key?(s)
    ape = r['activite_principale'].to_s
    bodacc_index[s] = {
      departement: r['departement'],
      ape_section: ape.length >= 2 ? ape[0..1] : nil
    }
  end
end

# ─── Snapshot ────────────────────────────────────────────────────────

associations = Association.order(:siren).to_a
puts "[Snapshot prospectif — #{DATE_SNAPSHOT}]"
puts "  Assos en DB           : #{associations.size}"
puts "  Index BODACC chargé   : #{bodacc_index.size} SIREN"

niveau_count = Hash.new(0)
ape_count    = Hash.new(0)
no_score     = 0
no_bodacc    = 0

CSV.open(OUTPUT_CSV, 'wb') do |out|
  out << CSV_HEADERS
  associations.each do |a|
    detail = a.score_detail || {}
    bod    = bodacc_index[a.siren] || {}

    niveau_count[a.niveau_vigi || '?'] += 1
    no_score += 1 if a.score_vigi.nil?
    no_bodacc += 1 if bod.empty?
    section = bod[:ape_section] || '?'
    ape_count[section] += 1

    out << [
      a.siren,
      a.cloture,
      a.nom,
      a.ville,
      bod[:departement],
      bod[:ape_section],
      a.score_vigi,
      a.niveau_vigi,
      detail['rentabilite'],
      detail['solidite'],
      detail['liquidite'],
      detail['autonomie'],
      detail['gouvernance'],
      DATE_SNAPSHOT
    ]
  end
end

puts ''
puts '─── Distribution par niveau ───'
%w[A B C D E ?].each do |n|
  next if niveau_count[n].zero?
  pct = (100.0 * niveau_count[n] / associations.size).round(1)
  puts "  #{n} : #{niveau_count[n].to_s.rjust(3)}  (#{pct}%)"
end

puts ''
puts '─── Distribution par section APE ───'
ape_count.sort_by { |_, n| -n }.each do |k, n|
  pct = (100.0 * n / associations.size).round(1)
  puts "  #{k}  : #{n.to_s.rjust(3)}  (#{pct}%)"
end

puts ''
puts "  Sans score_vigi              : #{no_score}"
puts "  Sans entrée BODACC enrichi   : #{no_bodacc}"
puts "  → #{OUTPUT_CSV}"
