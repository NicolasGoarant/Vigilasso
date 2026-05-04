#!/usr/bin/env ruby
require "net/http"
require "uri"
require "json"
require "csv"

INPUT  = "bodacc_associations_dedup_2020_2022.csv"
OUTPUT = "bodacc_associations_enrichi_2020_2022.csv"
API    = "https://recherche-entreprises.api.gouv.fr/search"

def fetch(siren)
  uri = URI(API)
  uri.query = URI.encode_www_form(q: siren)
  res = Net::HTTP.get_response(uri)
  return nil unless res.is_a?(Net::HTTPSuccess)
  data = JSON.parse(res.body)
  data["results"]&.first
end

input_rows = CSV.read(INPUT, headers: true)
total = input_rows.size
puts "[info] Enrichissement de #{total} SIREN historiques"

new_headers = input_rows.headers + %w[nom_officiel nature_juridique tranche_effectif activite_principale categorie etat]

CSV.open(OUTPUT, "w", write_headers: true, headers: new_headers) do |csv|
  input_rows.each_with_index do |row, i|
    siren = row["siren"]
    enriched = fetch(siren) rescue nil
    if enriched
      row_out = row.fields + [
        enriched["nom_complet"],
        enriched["nature_juridique"],
        enriched["tranche_effectif_salarie"],
        enriched["activite_principale"],
        enriched["categorie_entreprise"],
        enriched["etat_administratif"]
      ]
    else
      row_out = row.fields + [nil]*6
    end
    csv << row_out
    puts "[#{i+1}/#{total}]" if (i+1) % 100 == 0
    sleep 0.1
  end
end

puts "\n[done] -> #{OUTPUT}"

all = CSV.read(OUTPUT, headers: true)
assos_9220 = all.select { |r| r["nature_juridique"] == "9220" }
grosses = assos_9220.select { |r| (r["tranche_effectif"] || "00").to_i >= 3 }
puts "\n=== Stats ==="
puts "Assos confirmées (9220)        : #{assos_9220.size}/#{total}"
puts "Probablement >153k€ (>= tr.03) : #{grosses.size}"
