#!/usr/bin/env ruby
require "csv"
require "set"

INPUT_NEW = "bodacc_associations_positifs_2020_2022.csv"
INPUT_OLD = "bodacc_associations_dedup.csv"
OUTPUT    = "bodacc_associations_dedup_2020_2022.csv"

siren_old = Set.new
CSV.foreach(INPUT_OLD, headers: true) { |r| siren_old << r["siren"] if r["siren"] }
puts "SIREN déjà connus (2023-2025) : #{siren_old.size}"

by_siren = {}
CSV.foreach(INPUT_NEW, headers: true) do |row|
  siren = row["siren"]
  next if siren.nil? || siren.empty?
  date = row["date_jugement"] || row["date_parution"]
  if by_siren[siren].nil? || date < by_siren[siren]["date_jugement"].to_s
    by_siren[siren] = row
  end
end

nouveaux = by_siren.reject { |s, _| siren_old.include?(s) }

CSV.open(OUTPUT, "w", write_headers: true, headers: by_siren.values.first.headers) do |csv|
  nouveaux.values.each { |row| csv << row }
end

puts "SIREN uniques 2020-2022     : #{by_siren.size}"
puts "Déjà connus dans 2023-2025  : #{by_siren.size - nouveaux.size}"
puts "Nouveaux SIREN à enrichir   : #{nouveaux.size} -> #{OUTPUT}"
