#!/usr/bin/env ruby
require "net/http"
require "uri"
require "json"
require "csv"

API = "https://bodacc-datadila.opendatasoft.com/api/explore/v2.1/catalog/datasets/annonces-commerciales/records"

# Filtre élargi : ajout de termes courants dans les noms d'associations
# qui ne contiennent pas le mot "association" lui-même
TERMES = ["association", "club", "comité", "fédération", "fondation",
          "maison des", "amicale", "syndicat", "ligue", "union",
          "centre social", "MJC", "OGEC", "EHPAD"]

WHERE_PARTS = TERMES.map { |t| "commercant like \"#{t}\"" }.join(" OR ")
WHERE = "familleavis=\"collective\" AND (#{WHERE_PARTS}) AND dateparution>=\"2023-01-01\""

PAGE_SIZE = 100
OUTPUT = "bodacc_associations_positifs_elargi.csv"

def fetch_page(offset)
  uri = URI(API)
  uri.query = URI.encode_www_form(where: WHERE, limit: PAGE_SIZE, offset: offset, order_by: "dateparution desc")
  JSON.parse(Net::HTTP.get(uri))
end

def parse_record(r)
  j = r["jugement"] ? JSON.parse(r["jugement"]) : {}
  siren = r["registre"]&.find { |x| x =~ /\A\d{9}\z/ }
  [siren, r["commercant"], r["ville"], r["cp"], r["numerodepartement"],
   r["dateparution"], j["date"], j["nature"], j["famille"], r["id"]]
end

first = fetch_page(0)
total = first["total_count"]
puts "[info] #{total} annonces à récupérer (filtre élargi)"

headers = %w[siren nom ville code_postal departement date_parution date_jugement nature_jugement famille_jugement bodacc_id]
CSV.open(OUTPUT, "w", write_headers: true, headers: headers) do |csv|
  offset = 0
  loop do
    page = offset.zero? ? first : fetch_page(offset)
    break if page["results"].empty?
    page["results"].each { |r| csv << parse_record(r) }
    offset += PAGE_SIZE
    puts "[progress] #{[offset, total].min}/#{total}"
    break if offset >= total
    sleep 0.3
  end
end

puts "[done] CSV écrit dans #{OUTPUT}"
