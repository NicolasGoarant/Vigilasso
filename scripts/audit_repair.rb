#!/usr/bin/env ruby
# scripts/audit_repair.rb
#
# Répare audit_pdfs.csv qui contient un mix de deux schemas (le sample
# initial a été écrit sans la colonne `siren`, le mode all l'a ajoutée).
# Réécrit le CSV avec un schema uniforme à 10 colonnes.
#
# Après réparation, relance `ruby scripts/audit_pdfs.rb all` pour
# afficher le bilan correct et régénérer sirens_for_phase3.csv.

require 'csv'

PROJECT_ROOT = File.expand_path('..', __dir__)
DATA_DIR     = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data')
INPUT        = File.join(DATA_DIR, 'audit_pdfs.csv')
OUTPUT       = File.join(DATA_DIR, 'audit_pdfs_fixed.csv')
VERIFIED_CSV = File.join(DATA_DIR, 'sirens_verified.csv')

NEW_HEADER = %w[url title siren primary categories
                mentions_deficit mentions_fonds_propres_negatifs
                mentions_tresorerie_tendue mentions_dependance_subventions
                synthese]

abort "Pas de #{INPUT}, rien à réparer." unless File.exist?(INPUT)

# Index SIREN par URL pour enrichir les anciennes lignes du sample
siren_by_url = {}
if File.exist?(VERIFIED_CSV)
  CSV.foreach(VERIFIED_CSV, headers: true) do |r|
    siren_by_url[r['url']] = r['siren'] if r['siren'].to_s.size.positive?
  end
end

stats = { from_old: 0, from_new: 0, dropped: 0 }

CSV.open(OUTPUT, 'wb') do |out|
  out << NEW_HEADER

  CSV.foreach(INPUT).with_index do |row, idx|
    next if idx.zero? # ancien header

    case row.size
    when 9
      # Ancien format (sample) : url,title,primary,categories,...,synthese
      # On insère le SIREN depuis sirens_verified.csv si dispo
      url = row[0]
      siren = siren_by_url[url]
      out << [url, row[1], siren, *row[2..-1]]
      stats[:from_old] += 1
    when 10
      # Nouveau format (mode all) : déjà bon
      out << row
      stats[:from_new] += 1
    else
      warn "  ligne #{idx} : #{row.size} colonnes, ignorée"
      stats[:dropped] += 1
    end
  end
end

puts "Anciennes lignes (sample, +siren reconstruit) : #{stats[:from_old]}"
puts "Nouvelles lignes (mode all, conservées)        : #{stats[:from_new]}"
puts "Lignes ignorées                                : #{stats[:dropped]}"
puts ''
puts "  → #{OUTPUT}"
puts ''
puts "Pour appliquer la réparation :"
puts "  mv #{OUTPUT} #{INPUT}"
puts "  ruby scripts/audit_pdfs.rb all   # affiche le bilan correct"
