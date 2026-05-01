#!/usr/bin/env ruby
require "csv"

INPUT  = "bodacc_associations_positifs.csv"
OUTPUT = "bodacc_associations_dedup.csv"

by_siren = {}
CSV.foreach(INPUT, headers: true) do |row|
  siren = row["siren"]
  next if siren.nil? || siren.empty?
  date = row["date_jugement"] || row["date_parution"]
  if by_siren[siren].nil? || date < by_siren[siren]["date_jugement"].to_s
    by_siren[siren] = row
  end
end

CSV.open(OUTPUT, "w", write_headers: true, headers: by_siren.values.first.headers) do |csv|
  by_siren.values.each { |row| csv << row }
end

puts "[done] #{by_siren.size} associations uniques avec SIREN -> #{OUTPUT}"

puts "\n=== Répartition par nature de jugement ==="
by_siren.values.group_by { |r| r["nature_jugement"] }
        .sort_by { |_, v| -v.size }
        .each { |k, v| puts "  #{v.size.to_s.rjust(4)}  #{k}" }

puts "\n=== Répartition par année de jugement ==="
by_siren.values.group_by { |r| (r["date_jugement"] || r["date_parution"])[0,4] }
        .sort
        .each { |k, v| puts "  #{k}: #{v.size}" }
