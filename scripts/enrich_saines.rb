#!/usr/bin/env ruby
require "net/http"
require "uri"
require "json"
require "csv"

PDF_DIR = "data/pdfs_saines"
OUTPUT  = "data/saines_enrichi.csv"
API     = "https://recherche-entreprises.api.gouv.fr/search"

def fetch(siren)
  uri = URI(API)
  uri.query = URI.encode_www_form(q: siren)
  res = Net::HTTP.get_response(uri)
  return nil unless res.is_a?(Net::HTTPSuccess)
  data = JSON.parse(res.body)
  data["results"]&.first
end

# Récupère les SIREN uniques depuis les noms de fichiers
sirens = Dir["#{PDF_DIR}/*.pdf"].map { |f| File.basename(f).split("_").first }.uniq.sort
puts "[info] #{sirens.size} SIREN saines à enrichir"

CSV.open(OUTPUT, "w", write_headers: true,
         headers: %w[siren nom_officiel nature_juridique tranche_effectif activite_principale categorie etat region departement]) do |csv|

  sirens.each_with_index do |siren, i|
    enriched = fetch(siren) rescue nil
    if enriched
      csv << [
        siren,
        enriched["nom_complet"],
        enriched["nature_juridique"],
        enriched["tranche_effectif_salarie"],
        enriched["activite_principale"],
        enriched["categorie_entreprise"],
        enriched["etat_administratif"],
        enriched.dig("siege", "region"),
        enriched.dig("siege", "departement")
      ]
    else
      csv << [siren, nil, nil, nil, nil, nil, nil, nil, nil]
    end
    puts "[#{i+1}/#{sirens.size}] #{siren}" if (i+1) % 20 == 0
    sleep 0.1
  end
end

puts "\n[done] -> #{OUTPUT}"
