# lib/tasks/scrape_jo.rake
#
# Scraping des comptes annuels d'associations depuis le Journal Officiel (JOAFE)
# Source : API OpenDataSoft - dataset jo_associations, refine.source=dca
#
# Usage :
#   rake scrape_jo:run                          # scrape MJC (défaut)
#   rake scrape_jo:run Q=maison ROWS=200        # recherche personnalisée
#   rake scrape_jo:run Q=maison DRY_RUN=true    # aperçu sans télécharger
#
# Les PDFs sont enregistrés dans tmp/jo_pdfs/{SIREN}_{DDMMYYYY}.pdf
# Exemple : 313471468_31122018.pdf  (= champ `id` de l'API + extension)

require "net/http"
require "uri"
require "json"
require "fileutils"
require "time"

namespace :scrape_jo do

  # ─── Configuration ──────────────────────────────────────────────────────────

  API_BASE    = "https://www.journal-officiel.gouv.fr/api/records/1.0/search/"
  PDF_BASE    = "https://www.journal-officiel.gouv.fr/documents/associations"
  OUTPUT_DIR  = Rails.root.join("tmp", "jo_pdfs")
  BATCH_SIZE  = 100   # max autorisé par l'API OpenDataSoft
  SLEEP_SEC   = 0.8   # pause entre requêtes pour ne pas surcharger le serveur

  # ─── Tâche principale ───────────────────────────────────────────────────────

  desc "Scrape les comptes annuels d'associations depuis le JOAFE et télécharge les PDFs"
  task run: :environment do
    query   = ENV.fetch("Q",    "MJC")
    dry_run = ENV.fetch("DRY_RUN", "false") == "true"
    max     = ENV["MAX_ROWS"]&.to_i   # optionnel : limiter le total

    puts "=" * 60
    puts "  Vigil'Asso — Scraping JOAFE"
    puts "  Requête  : #{query}"
    puts "  Mode     : #{dry_run ? '🔍 DRY RUN (aucun téléchargement)' : '⬇️  Téléchargement actif'}"
    puts "  Sortie   : #{OUTPUT_DIR}"
    puts "=" * 60

    FileUtils.mkdir_p(OUTPUT_DIR) unless dry_run

    stats = { found: 0, downloaded: 0, skipped: 0, errors: 0 }
    start = 0

    loop do
      records, total = fetch_page(query, start, BATCH_SIZE)
      break if records.nil? || records.empty?

      stats[:found] = total if start == 0
      puts "\n📄 Page #{start / BATCH_SIZE + 1} — #{records.size} enregistrements (total : #{total})"

      records.each do |record|
        fields    = record["fields"] || {}
        record_id = record["recordid"]

        # Le champ `id` est la clé composite : "{SIREN}_{DDMMYYYY}"
        # Exemple : "313471468_31122018"
        jo_id = fields["id"].to_s.strip
        siren = extract_siren(fields)

        if jo_id.blank? || siren.blank?
          puts "  ⚠️  id ou siren manquant pour recordid=#{record_id} — ignoré"
          stats[:errors] += 1
          next
        end

        filename    = "#{jo_id}.pdf"
        output_path = OUTPUT_DIR.join(filename)

        if !dry_run && output_path.exist?
          puts "  ✅ Déjà téléchargé : #{filename}"
          stats[:skipped] += 1
          next
        end

        pdf_url = build_pdf_url(siren, jo_id)

        if dry_run
          puts "  🔍 [DRY RUN] #{filename}"
          puts "              #{pdf_url}"
          stats[:downloaded] += 1
          next
        end

        success = download_pdf(pdf_url, output_path, filename)
        success ? stats[:downloaded] += 1 : stats[:errors] += 1

        sleep(SLEEP_SEC)
      end

      start += BATCH_SIZE
      break if max && start >= max
      break if start >= total

      sleep(SLEEP_SEC)
    end

    puts "\n" + "=" * 60
    puts "  Résultats"
    puts "  Trouvés    : #{stats[:found]}"
    puts "  Téléchargés: #{stats[:downloaded]}"
    puts "  Ignorés    : #{stats[:skipped]}"
    puts "  Erreurs    : #{stats[:errors]}"
    puts "=" * 60
  end

  # ─── Méthodes privées ───────────────────────────────────────────────────────

  private

  # Appelle l'API OpenDataSoft et retourne [records, total]
  def self.fetch_page(query, start, rows)
    params = {
      "dataset"       => "jo_associations",
      "q"             => query,
      "refine.source" => "dca",         # dépôt des comptes annuels uniquement
      "rows"          => rows.to_s,
      "start"         => start.to_s,
      "sort"          => "dateparution",
      "timezone"      => "Europe/Paris"
    }

    uri       = URI(API_BASE)
    uri.query = URI.encode_www_form(params)

    puts "  → GET #{uri}" if ENV["VERBOSE"]

    response = Net::HTTP.get_response(uri)

    unless response.is_a?(Net::HTTPSuccess)
      puts "  ❌ Erreur API : #{response.code} #{response.message}"
      return [nil, 0]
    end

    data    = JSON.parse(response.body)
    total   = data.dig("nhits") || 0
    records = data.dig("records") || []

    [records, total]

  rescue JSON::ParserError => e
    puts "  ❌ Erreur JSON : #{e.message}"
    [nil, 0]
  rescue StandardError => e
    puts "  ❌ Erreur réseau : #{e.message}"
    [nil, 0]
  end

  # Construit l'URL du PDF
  # Pattern extrait du HTML source du JOAFE :
  # /telechargements/ASSOCIATIONS/DCA/PDF/{YYYY}/{DDMM}/{id}.pdf
  #
  # Exemple : id = "313273153_31122024"
  #   filedate   = "31122024"
  #   jjmmfolder = "3112"   (filedate[0..3])
  #   yearfolder = "2024"   (filedate[4..7])
  #   → /telechargements/ASSOCIATIONS/DCA/PDF/2024/3112/313273153_31122024.pdf
  def self.build_pdf_url(_siren, jo_id)
    filedate   = jo_id.split("_")[1]   # "31122024"
    jjmmfolder = filedate[0..3]         # "3112"
    yearfolder = filedate[4..7]         # "2024"
    "https://www.journal-officiel.gouv.fr/telechargements/ASSOCIATIONS/DCA/PDF/#{yearfolder}/#{jjmmfolder}/#{jo_id}.pdf"
  end

  # Télécharge un PDF vers output_path
  def self.download_pdf(url, output_path, filename)
    uri      = URI(url)
    response = follow_redirects(uri)

    unless response.is_a?(Net::HTTPSuccess)
      puts "  ❌ #{filename} — HTTP #{response.code}"
      puts "     URL : #{url}"
      return false
    end

    content_type = response["content-type"] || ""

    if content_type.include?("text/html")
      puts "  ⚠️  #{filename} — Reçu du HTML (URL incorrecte ou page de détail)"
      puts "     URL : #{url}"
      return false
    end

    unless content_type.include?("pdf") || content_type.include?("octet-stream")
      puts "  ⚠️  #{filename} — Content-Type inattendu : #{content_type}"
    end

    File.binwrite(output_path, response.body)
    size_kb = (response.body.bytesize / 1024.0).round(1)
    puts "  ⬇️  #{filename} (#{size_kb} Ko)"
    true

  rescue StandardError => e
    puts "  ❌ #{filename} — #{e.class}: #{e.message}"
    false
  end

  # Suit les redirections HTTP (max 5)
  def self.follow_redirects(uri, limit = 5)
    raise "Trop de redirections" if limit == 0

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.read_timeout = 30
    http.open_timeout = 10

    request = Net::HTTP::Get.new(uri.request_uri, {
      "User-Agent" => "Vigil'Asso/1.0 (scraper academique; contact: vigilasso@example.com)"
    })

    response = http.request(request)

    if response.is_a?(Net::HTTPRedirection) && response["location"]
      new_uri = URI.join(uri.to_s, response["location"])
      follow_redirects(new_uri, limit - 1)
    else
      response
    end
  end

  # Extraction du SIREN — champ confirmé : dca_siren
  def self.extract_siren(fields)
    (fields["dca_siren"] || "").to_s.strip
  end

  # Parse la date ISO 8601 du JOAFE et retourne DDMMYYYY
  # Confirmé : "2018-12-31T12:00:00+00:00" → "31122018"
  # (correspond au suffixe du champ `id`)
  def self.parse_date_ddmmyyyy(iso_string)
    return "" if iso_string.blank?
    t = Time.parse(iso_string.to_s)
    t.strftime("%d%m%Y")
  rescue ArgumentError
    ""
  end

end
