#!/usr/bin/env ruby
require "csv"
require "set"

INPUT_NEW = "bodacc_associations_positifs_elargi.csv"
INPUT_OLD = "bodacc_associations_dedup.csv"
OUTPUT    = "bodacc_associations_dedup_elargi.csv"

# Charge les SIREN déjà connus
siren_old = Set.new
CSV.foreach(INPUT_OLD, headers: true) { |r| siren_old << r["siren"] if r["siren"] }

# Dédoublonne le nouveau, garde la première occurrence par SIREN (plus ancien jugement)
by_siren = {}
CSV.foreach(INPUT_NEW, headers: true) do |row|
  siren = row["siren"]
  next if siren.nil? || siren.empty?
  date = row["date_jugement"] || row["date_parution"]
  if by_siren[siren].nil? || date < by_siren[siren]["date_jugement"].to_s
    by_siren[siren] = row
  end
end

# Écrit uniquement les nouveaux SIREN (pas dans l'ancien dataset)
nouveaux = by_siren.reject { |s, _| siren_old.include?(s) }

CSV.open(OUTPUT, "w", write_headers: true, headers: by_siren.values.first.headers) do |csv|
  nouveaux.values.each { |row| csv << row }
end

puts "Total dans nouveau filtre : #{by_siren.size} SIREN uniques"
puts "Déjà dans ancien dataset  : #{by_siren.size - nouveaux.size}"
puts "Nouveaux SIREN à traiter  : #{nouveaux.size} -> #{OUTPUT}"

# Stats
puts "\n=== Répartition par nature de jugement (nouveaux) ==="
nouveaux.values.group_by { |r| r["nature_jugement"] }
        .sort_by { |_, v| -v.size }
        .first(10)
        .each { |k, v| puts "  #{v.size.to_s.rjust(4)}  #{k}" }
