#!/usr/bin/env ruby
require "net/http"
require "uri"
require "json"
require "csv"

INPUT  = "bodacc_associations_dedup_elargi.csv"
OUTPUT = "bodacc_associations_enrichi_elargi.csv"
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
puts "[info] Enrichissement de #{total} nouveaux SIREN"

new_headers = input_rows.headers + %w[nom_officiel nature_juridique tranche_effectif activite_principale categorie etat rna]

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
        enriched["etat_administratif"],
        enriched.dig("complements", "identifiant_association")
      ]
    else
      row_out = row.fields + [nil]*7
    end

    csv << row_out
    puts "[#{i+1}/#{total}] #{siren} -> #{enriched&.dig('tranche_effectif_salarie') || 'KO'}" if (i+1) % 50 == 0
    sleep 0.1
  end
end

puts "\n[done] -> #{OUTPUT}"

all = CSV.read(OUTPUT, headers: true)
assos_confirmees = all.select { |r| r["nature_juridique"] == "9220" }
puts "\n=== Stats ==="
puts "Assos confirmées (nature_juridique=9220) : #{assos_confirmees.size}/#{total}"

grosses = assos_confirmees.select { |r| (r["tranche_effectif"] || "00").to_i >= 3 }
puts "Probablement >153k€ (tranche >=03)       : #{grosses.size}"
