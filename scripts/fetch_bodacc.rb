#!/usr/bin/env ruby
require "net/http"
require "uri"
require "csv"
require "fileutils"
require "date"

INPUT  = "bodacc_associations_enrichi.csv"
PDF_DIR = "data/pdfs_positifs"
LOG    = "data/telechargements_log.csv"
SLEEP  = 0.4
DATES_CLOTURE_PROBABLES = ["3112", "3006", "3108", "3103", "3009"]
ANNEES_AVANT_DEFAILLANCE = [1, 2, 3]

FileUtils.mkdir_p(PDF_DIR)
FileUtils.mkdir_p(File.dirname(LOG))

def url_for(siren, year, ddmm)
  "https://www.journal-officiel.gouv.fr/telechargements/ASSOCIATIONS/DCA/PDF/#{year}/#{ddmm}/#{siren}_#{ddmm}#{year}.pdf"
end

def head_exists?(url)
  uri = URI(url)
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
    http.read_timeout = 10
    res = http.head(uri.request_uri)
    return res.code == "200"
  end
rescue
  false
end

def download(url, path)
  uri = URI(url)
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
    res = http.get(uri.request_uri)
    if res.code == "200"
      File.binwrite(path, res.body)
      return res.body.bytesize
    end
    nil
  end
rescue
  nil
end

candidates = CSV.read(INPUT, headers: true).select do |r|
  r["nature_juridique"] == "9220" &&
  r["etat"] != nil &&
  (r["tranche_effectif"] || "00").to_i >= 3
end

puts "[info] #{candidates.size} associations candidates pour téléchargement"

stats = { found: 0, downloaded: 0, missing: 0, errors: 0 }

CSV.open(LOG, "w", write_headers: true,
         headers: %w[siren nom date_defaillance year_tested ddmm_tested url status taille_octets fichier]) do |log|

  candidates.each_with_index do |row, idx|
    siren = row["siren"]
    nom   = row["nom"]
    date_def = row["date_jugement"] || row["date_parution"]
    next unless date_def && date_def =~ /^\d{4}/
    year_def = date_def[0,4].to_i

    ANNEES_AVANT_DEFAILLANCE.each do |delta|
      year = year_def - delta
      DATES_CLOTURE_PROBABLES.each do |ddmm|
        url = url_for(siren, year, ddmm)
        next unless head_exists?(url)

        fichier = "#{siren}_#{ddmm}#{year}.pdf"
        path = File.join(PDF_DIR, fichier)

        if File.exist?(path)
          log << [siren, nom, date_def, year, ddmm, url, "skip_existe", File.size(path), fichier]
          stats[:found] += 1
        else
          taille = download(url, path)
          if taille
            log << [siren, nom, date_def, year, ddmm, url, "ok", taille, fichier]
            stats[:downloaded] += 1
            stats[:found] += 1
          else
            log << [siren, nom, date_def, year, ddmm, url, "echec_dl", nil, nil]
            stats[:errors] += 1
          end
        end
        sleep SLEEP
      end
    end

    puts "[#{idx+1}/#{candidates.size}] siren=#{siren} | trouvés=#{stats[:found]} téléchargés=#{stats[:downloaded]}"
  end
end

puts "\n=== Stats finales ==="
puts "  PDFs téléchargés     : #{stats[:downloaded]}"
puts "  PDFs déjà présents   : #{stats[:found] - stats[:downloaded]}"
puts "  Erreurs              : #{stats[:errors]}"
puts "  Log : #{LOG}"
puts "  PDFs : #{PDF_DIR}/"
