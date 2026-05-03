#!/usr/bin/env ruby
require "net/http"
require "uri"
require "csv"
require "fileutils"

INPUT  = "/tmp/sirens_saines_100.txt"
PDF_DIR = "data/pdfs_saines"
LOG    = "data/telechargements_saines_historique_log.csv"
SLEEP  = 0.4

ANNEES_HISTORIQUE = [2022, 2021, 2020]
DATES_CLOTURE = ["3112", "3006", "3108", "3103", "3009"]

FileUtils.mkdir_p(PDF_DIR)

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

sirens = File.readlines(INPUT, chomp: true)
puts "[info] #{sirens.size} SIREN saines à compléter"

stats = { found: 0, downloaded: 0, skipped_existe: 0 }

CSV.open(LOG, "w", write_headers: true,
         headers: %w[siren year ddmm url status taille_octets fichier]) do |log|

  sirens.each_with_index do |siren, idx|
    siren = siren.strip
    next if siren.empty?

    found_for_this = 0
    ANNEES_HISTORIQUE.each do |year|
      DATES_CLOTURE.each do |ddmm|
        fichier = "#{siren}_#{ddmm}#{year}.pdf"
        path = File.join(PDF_DIR, fichier)

        if File.exist?(path)
          stats[:skipped_existe] += 1
          found_for_this += 1
          next
        end

        url = url_for(siren, year, ddmm)
        next unless head_exists?(url)

        taille = download(url, path)
        if taille
          log << [siren, year, ddmm, url, "ok", taille, fichier]
          stats[:downloaded] += 1
          stats[:found] += 1
          found_for_this += 1
        else
          log << [siren, year, ddmm, url, "echec_dl", nil, nil]
        end
        sleep SLEEP
      end
    end

    if (idx+1) % 10 == 0
      puts "[#{idx+1}/#{sirens.size}] siren=#{siren} | nouveaux téléchargés=#{stats[:downloaded]}"
    end
  end
end

puts "\n=== Téléchargement historique terminé ==="
puts "  Nouveaux PDFs : #{stats[:downloaded]}"
puts "  Déjà présents : #{stats[:skipped_existe]}"
