# lib/tasks/extract_financials.rake
#
# Extraction des données financières des comptes annuels via Claude Haiku
#
# Usage :
#   rake extract_financials:run                        # traite tous les PDFs non encore extraits
#   rake extract_financials:run LIMIT=50               # limite à 50 PDFs (test)
#   rake extract_financials:run PDF=779884329_31082022 # un seul PDF
#   rake extract_financials:run RETRY_ERRORS=true      # relance les PDFs en erreur
#   rake extract_financials:stats                      # bilan de l'extraction
#
# Coût estimé : ~$0.004 par PDF avec claude-haiku-4-5

require "net/http"
require "uri"
require "json"
require "open3"

namespace :extract_financials do

  PDF_DIR    = Rails.root.join("tmp", "jo_pdfs")
  MODEL      = "claude-haiku-4-5-20251001"
  MAX_TOKENS = 1024
  MAX_CHARS  = 12_000
  EXTRACT_SLEEP_SEC = 1.5
  API_URL    = "https://api.anthropic.com/v1/messages"

  desc "Extrait les données financières des PDFs via Claude Haiku"
  task run: :environment do
    limit        = ENV["LIMIT"]&.to_i
    single_pdf   = ENV["PDF"]
    retry_errors = ENV["RETRY_ERRORS"] == "true"

    puts "=" * 60
    puts "  Vigil'Asso — Extraction financière"
    puts "  Modèle  : #{MODEL}"
    puts "  Dossier : #{PDF_DIR}"
    puts "=" * 60

    pdfs = if single_pdf
      [PDF_DIR.join("#{single_pdf}.pdf")]
    else
      PDF_DIR.glob("*.pdf").sort
    end

    pdfs = pdfs.select do |path|
      jo_id  = path.basename(".pdf").to_s
      record = CompteAnnuel.find_by(jo_id: jo_id)
      if record.nil?
        true
      elsif retry_errors && record.statut == "erreur"
        true
      else
        false
      end
    end

    pdfs  = pdfs.first(limit) if limit
    total = pdfs.size

    puts "\n#{total} PDFs à traiter\n\n"
    return if total == 0

    stats = { ok: 0, erreur: 0, vide: 0 }

    pdfs.each_with_index do |pdf_path, idx|
      jo_id        = pdf_path.basename(".pdf").to_s
      siren, _rest = jo_id.split("_")
      print "[#{idx + 1}/#{total}] #{jo_id} ... "

      texte = extraire_texte(pdf_path)

      if texte.blank? || texte.length < 200
        puts "PDF vide ou illisible"
        CompteAnnuel.find_or_initialize_by(jo_id: jo_id).tap do |r|
          r.siren    = siren
          r.pdf_path = pdf_path.to_s
          r.statut   = "vide"
          r.save!
        end
        stats[:vide] += 1
        next
      end

      begin
        resultat = appeler_claude(texte, jo_id)

        CompteAnnuel.find_or_initialize_by(jo_id: jo_id).tap do |r|
          r.siren        = resultat["siren"] || siren
          r.jo_id        = jo_id
          r.pdf_path     = pdf_path.to_s
          r.date_cloture = parse_date(resultat["date_cloture"])
          r.exercice     = r.date_cloture&.year
          r.statut       = "ok"
          r.raw_json     = resultat.to_json
          r.erreur       = nil

          %w[
            total_bilan total_actif_immobilise total_actif_circulant
            fonds_propres dettes_total provisions
            produits_exploitation charges_exploitation resultat_exploitation
            produits_financiers charges_financieres resultat_financier
            resultat_exceptionnel resultat_net
            subventions masse_salariale charges_sociales
          ].each { |c| r.send("#{c}=", to_int(resultat[c])) }

          r.effectif_etp = resultat["effectif_etp"]&.to_f
          r.save!
        end

        net   = resultat["resultat_net"].to_i
        signe = net >= 0 ? "+" : ""
        puts "OK  resultat #{signe}#{net} EUR"
        stats[:ok] += 1

      rescue => e
        puts "ERREUR  #{e.message[0..80]}"
        CompteAnnuel.find_or_initialize_by(jo_id: jo_id).tap do |r|
          r.siren    = siren
          r.pdf_path = pdf_path.to_s
          r.statut   = "erreur"
          r.erreur   = e.message
          r.save!
        end
        stats[:erreur] += 1
      end

      sleep(EXTRACT_SLEEP_SEC)
    end

    puts "\n" + "=" * 60
    puts "  OK      : #{stats[:ok]}"
    puts "  Vides   : #{stats[:vide]}"
    puts "  Erreurs : #{stats[:erreur]}"
    puts "  Cout API estime : ~$#{(stats[:ok] * 0.004).round(2)}"
    puts "=" * 60
  end

  desc "Affiche les statistiques d'extraction"
  task stats: :environment do
    total  = CompteAnnuel.count
    ok     = CompteAnnuel.where(statut: "ok").count
    vides  = CompteAnnuel.where(statut: "vide").count
    errors = CompteAnnuel.where(statut: "erreur").count
    pdfs   = PDF_DIR.glob("*.pdf").count

    puts "=" * 60
    puts "  PDFs sur disque : #{pdfs}"
    puts "  Traites         : #{total}"
    puts "    OK            : #{ok}"
    puts "    Vides         : #{vides}"
    puts "    Erreurs       : #{errors}"
    puts "  Restants        : #{pdfs - total}"
    puts "  Cout estime     : ~$#{(ok * 0.004).round(2)}"
    puts "=" * 60

    if ok > 0
      avg   = CompteAnnuel.where(statut: "ok").where.not(total_bilan: nil).average(:total_bilan)&.to_i
      negs  = CompteAnnuel.where(statut: "ok").where("resultat_net < 0").count
      puts "  Bilan moyen    : #{avg} EUR"
      puts "  En deficit     : #{negs} (#{(negs * 100.0 / ok).round(1)}%)"
    end
  end

  private

  def self.extraire_texte(pdf_path)
    stdout, _stderr, status = Open3.capture3("pdftotext", pdf_path.to_s, "-")
    return "" unless status.success?
    stdout.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")[0, MAX_CHARS]
  end

  def self.appeler_claude(texte, jo_id)
    api_key = ENV["ANTHROPIC_API_KEY"]
    raise "ANTHROPIC_API_KEY manquant" if api_key.blank?

    prompt = <<~PROMPT
      Tu es un expert-comptable specialise dans les comptes annuels d'associations francaises.

      Extrais les donnees financieres du PDF ci-dessous (JOAFE id: #{jo_id}).
      Reponds UNIQUEMENT avec un objet JSON valide, sans texte ni markdown autour.

      Champs (euros entiers, null si absent) :
      siren, date_cloture (YYYY-MM-DD), total_bilan, total_actif_immobilise,
      total_actif_circulant, fonds_propres, dettes_total, provisions,
      produits_exploitation, charges_exploitation, resultat_exploitation,
      produits_financiers, charges_financieres, resultat_financier,
      resultat_exceptionnel, resultat_net, subventions,
      masse_salariale, charges_sociales, effectif_etp (decimal).

      Texte du PDF :
      #{texte}
    PROMPT

    uri     = URI(API_URL)
    http    = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.read_timeout = 60

    req = Net::HTTP::Post.new(uri.path, {
      "Content-Type"      => "application/json",
      "x-api-key"         => api_key,
      "anthropic-version" => "2023-06-01"
    })
    req.body = {
      model:      MODEL,
      max_tokens: MAX_TOKENS,
      messages:   [{ role: "user", content: prompt }]
    }.to_json

    res = http.request(req)
    raise "API #{res.code}: #{res.body[0..200]}" unless res.is_a?(Net::HTTPSuccess)

    content = JSON.parse(res.body).dig("content", 0, "text").to_s.strip
    content = content.gsub(/\A```(?:json)?\n?/, "").gsub(/\n?```\z/, "").strip

    JSON.parse(content)
  rescue JSON::ParserError => e
    raise "JSON invalide: #{e.message} | #{content&.first(100)}"
  end

  def self.parse_date(str)
    return nil if str.blank?
    Date.parse(str)
  rescue ArgumentError
    nil
  end

  def self.to_int(val)
    return nil if val.nil?
    val.to_s.gsub(/[^\d\-]/, "").to_i
  end

end
