#!/usr/bin/env ruby
require "net/http"
require "uri"
require "json"
require "csv"

INPUT  = "/tmp/sirens_saines_400_nouvelles.txt"
OUTPUT = "data/saines_400_enrichi.csv"
API    = "https://recherche-entreprises.api.gouv.fr/search"

def fetch(siren)
  uri = URI(API)
  uri.query = URI.encode_www_form(q: siren)
  res = Net::HTTP.get_response(uri)
  return nil unless res.is_a?(Net::HTTPSuccess)
  data = JSON.parse(res.body)
  data["results"]&.first
end

sirens = File.readlines(INPUT, chomp: true).map(&:strip).reject(&:empty?)
puts "[info] Enrichissement de #{sirens.size} SIREN"

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
    puts "[#{i+1}/#{sirens.size}]" if (i+1) % 50 == 0
    sleep 0.1
  end
end

puts "\n[done] -> #{OUTPUT}"

# Stats
all = CSV.read(OUTPUT, headers: true)
assos_9220 = all.select { |r| r["nature_juridique"] == "9220" }
puts "\n=== Stats ==="
puts "Total enrichis        : #{all.size}"
puts "Vraies assos (9220)   : #{assos_9220.size}"
puts ""
puts "Distribution tranches d'effectif (sur les 9220) :"
assos_9220.group_by { |r| r["tranche_effectif"] || "??" }
          .sort_by { |k, _| k.to_s }
          .each { |k, v| puts "  tranche #{k.to_s.rjust(2)}: #{v.size}" }

grosses = assos_9220.select { |r| (r["tranche_effectif"] || "00").to_i >= 3 }
puts "\nAssos >153k€ probables (tranche >=03) : #{grosses.size}"
