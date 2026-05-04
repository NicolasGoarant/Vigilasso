#!/usr/bin/env ruby
require "net/http"
require "uri"
require "csv"
require "fileutils"

INPUT  = "/tmp/sirens_defaill_2020_2022.txt"
PDF_DIR = "data/pdfs_positifs"
LOG    = "data/telechargements_defaill_2020_2022_log.csv"
SLEEP  = 0.3

ANNEES = [2022, 2021, 2020, 2019, 2018, 2017]
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

sirens = File.readlines(INPUT, chomp: true).map(&:strip).reject(&:empty?)
puts "[info] #{sirens.size} SIREN defaillantes 2020-2022 a tester"

stats = { tested: 0, downloaded: 0, skipped: 0 }

CSV.open(LOG, "w", write_headers: true,
         headers: %w[siren year ddmm url status taille_octets fichier]) do |log|

  sirens.each_with_index do |siren, idx|
    ANNEES.each do |year|
      DATES_CLOTURE.each do |ddmm|
        fichier = "#{siren}_#{ddmm}#{year}.pdf"
        path = File.join(PDF_DIR, fichier)
        if File.exist?(path)
          stats[:skipped] += 1
          next
        end

        url = url_for(siren, year, ddmm)
        stats[:tested] += 1
        next unless head_exists?(url)

        taille = download(url, path)
        if taille
          log << [siren, year, ddmm, url, "ok", taille, fichier]
          stats[:downloaded] += 1
        end
        sleep SLEEP
      end
    end

    if (idx+1) % 25 == 0
      puts "[#{idx+1}/#{sirens.size}] testes=#{stats[:tested]} telecharges=#{stats[:downloaded]}"
    end
  end
end

puts ""
puts "=== Resultats ==="
puts "  SIREN testes  : #{sirens.size}"
puts "  PDFs telecharges : #{stats[:downloaded]}"
