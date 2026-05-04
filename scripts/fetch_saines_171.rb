#!/usr/bin/env ruby
require "net/http"
require "uri"
require "csv"
require "fileutils"

INPUT  = "/tmp/sirens_saines_171.txt"
PDF_DIR = "data/pdfs_saines"
LOG    = "data/telechargements_saines_171_log.csv"
SLEEP  = 0.4

ANNEES = [2024, 2023, 2022, 2021, 2020]
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
puts "[info] #{sirens.size} SIREN à compléter"

stats = { downloaded: 0, skipped: 0 }

CSV.open(LOG, "w", write_headers: true,
         headers: %w[siren year ddmm url status taille_octets fichier]) do |log|

  sirens.each_with_index do |siren, idx|
    ANNEES.each do |year|
      DATES_CLOTURE.each do |ddmm|
        fichier = "#{siren}_#{ddmm}#{year}.pdf"
        path = File.join(PDF_DIR, fichier)
        next if File.exist?(path)

        url = url_for(siren, year, ddmm)
        next unless head_exists?(url)

        taille = download(url, path)
        if taille
          log << [siren, year, ddmm, url, "ok", taille, fichier]
          stats[:downloaded] += 1
        end
        sleep SLEEP
      end
    end
    puts "[#{idx+1}/#{sirens.size}] tél=#{stats[:downloaded]}" if (idx+1) % 10 == 0
  end
end

puts "\n[done] PDFs téléchargés : #{stats[:downloaded]}"
