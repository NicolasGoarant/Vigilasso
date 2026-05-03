#!/usr/bin/env ruby
require "net/http"
require "uri"
require "csv"
require "fileutils"

INPUT  = "/tmp/saines_avec_dates.csv"
PDF_DIR = "data/pdfs_saines"
LOG    = "data/telechargements_saines_log.csv"
SLEEP  = 0.4

FileUtils.mkdir_p(PDF_DIR)

def url_for(siren, ddmmyyyy)
  ddmm  = ddmmyyyy[0,4]
  yyyy  = ddmmyyyy[4,4]
  "https://www.journal-officiel.gouv.fr/telechargements/ASSOCIATIONS/DCA/PDF/#{yyyy}/#{ddmm}/#{siren}_#{ddmmyyyy}.pdf"
end

def download(url, path)
  uri = URI(url)
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
    http.read_timeout = 60
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

rows = CSV.read(INPUT, headers: false)
puts "[info] #{rows.size} dépôts à télécharger"

stats = { downloaded: 0, skipped: 0, errors: 0 }

CSV.open(LOG, "w", write_headers: true,
         headers: %w[siren date_cloture url status taille_octets fichier]) do |log|

  rows.each_with_index do |row, idx|
    siren = row[0]
    ddmmyyyy = row[1]
    next unless siren && ddmmyyyy

    url = url_for(siren, ddmmyyyy)
    fichier = "#{siren}_#{ddmmyyyy}.pdf"
    path = File.join(PDF_DIR, fichier)

    if File.exist?(path)
      log << [siren, ddmmyyyy, url, "skip_existe", File.size(path), fichier]
      stats[:skipped] += 1
    else
      taille = download(url, path)
      if taille
        log << [siren, ddmmyyyy, url, "ok", taille, fichier]
        stats[:downloaded] += 1
      else
        log << [siren, ddmmyyyy, url, "echec", nil, nil]
        stats[:errors] += 1
      end
      sleep SLEEP
    end

    if (idx+1) % 10 == 0
      puts "[#{idx+1}/#{rows.size}] tél=#{stats[:downloaded]} skip=#{stats[:skipped]} err=#{stats[:errors]}"
    end
  end
end

puts "\n=== Téléchargement terminé ==="
puts "  Téléchargés : #{stats[:downloaded]}"
puts "  Existants   : #{stats[:skipped]}"
puts "  Erreurs     : #{stats[:errors]}"
