#!/usr/bin/env ruby
require "net/http"
require "uri"
require "json"
require "base64"
require "csv"
require "fileutils"

PDF_DIR = "data/pdfs_positifs"
OUTPUT  = "data/scores_positifs.csv"
LOG_DIR = "data/scoring_logs"
API_KEY = ENV["ANTHROPIC_API_KEY"]
MODEL   = "claude-sonnet-4-5"
SLEEP_BETWEEN = 35

abort "ANTHROPIC_API_KEY manquante" if API_KEY.nil? || API_KEY.empty?
FileUtils.mkdir_p(LOG_DIR)

PROMPT = <<~PROMPT
  Tu es un expert-comptable spécialisé dans l'analyse financière des associations loi 1901 françaises.
  Analyse ce document comptable (bilan + compte de résultat) et extrais les données suivantes.
  Réponds UNIQUEMENT avec un objet JSON valide, sans texte avant ni après, sans balises markdown.

  Champs à extraire :
  - siren : numéro SIREN 9 chiffres (string, null si absent)
  - nom : nom de l'association (string)
  - ville : ville du siège social (string)
  - cloture : date de clôture de l'exercice au format YYYY-MM-DD (string)
  - total_produits : total des produits en euros (integer)
  - resultat_exploitation : résultat d'exploitation en euros, négatif si déficit (integer)
  - resultat_net : résultat net / excédent ou déficit en euros (integer)
  - fonds_propres : total fonds propres ou fonds associatifs en euros (integer)
  - tresorerie : disponibilités + valeurs mobilières de placement en euros (integer)
  - emprunts : emprunts auprès établissements de crédit en euros (integer, 0 si aucun)
  - total_bilan : total général du bilan en euros (integer)
  - subv_sur_produits_pct : part des subventions publiques dans les produits en % (integer)
  - masse_sal_pct : part masse salariale (salaires + charges sociales) dans les charges en % (integer)
  - fp_bilan_pct : fonds propres / total bilan en % (integer)
  - etp : effectif moyen en équivalent temps plein (decimal, null si absent)
  - cac_certifie : true si rapport commissaire aux comptes présent et certifié sans réserve (boolean)
  - statut : "excedent" si résultat net > 0, "deficit" si < 0, "ambigu" si excédent net mais déficit exploitation (string)
  - notes : observations importantes en 1-2 phrases max (string)
PROMPT

WEIGHTS = { rentabilite: 30, solidite: 25, liquidite: 20, autonomie: 15, gouvernance: 10 }
NIVEAUX = [
  { label: "A", min: 80 }, { label: "B", min: 60 }, { label: "C", min: 40 },
  { label: "D", min: 20 }, { label: "E", min: 0 }
]

def extract(pdf_path, retry_429: true)
  pdf_data = Base64.strict_encode64(File.binread(pdf_path))
  uri = URI("https://api.anthropic.com/v1/messages")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 180

  req = Net::HTTP::Post.new(uri)
  req["x-api-key"] = API_KEY
  req["anthropic-version"] = "2023-06-01"
  req["content-type"] = "application/json"
  req.body = {
    model: MODEL,
    max_tokens: 1024,
    messages: [{
      role: "user",
      content: [
        { type: "document", source: { type: "base64", media_type: "application/pdf", data: pdf_data } },
        { type: "text", text: PROMPT }
      ]
    }]
  }.to_json

  res = http.request(req)

  if res.code == "429" && retry_429
    puts "    [429 rate limit] pause 60s puis retry"
    sleep 60
    return extract(pdf_path, retry_429: false)
  end

  return { error: "HTTP #{res.code}: #{res.body[0,200]}" } unless res.code == "200"

  body = JSON.parse(res.body)
  raw = body.dig("content", 0, "text").to_s.gsub(/\A```json\n?/, "").gsub(/\n?```\z/, "").strip
  JSON.parse(raw)
rescue JSON::ParserError => e
  { error: "JSON: #{e.message}" }
rescue => e
  { error: "#{e.class}: #{e.message}" }
end

def score(d)
  detail = {}
  detail[:rentabilite] = if d["total_produits"].to_i > 0
    r = d["resultat_exploitation"].to_f / d["total_produits"]
    ((r + 0.3) / 0.6 * WEIGHTS[:rentabilite]).clamp(0, WEIGHTS[:rentabilite]).round(1)
  else 0 end

  detail[:solidite] = if d["total_bilan"].to_i > 0
    r = d["fonds_propres"].to_f / d["total_bilan"]
    (r / 0.8 * WEIGHTS[:solidite]).clamp(0, WEIGHTS[:solidite]).round(1)
  else 0 end

  detail[:liquidite] = if d["total_produits"].to_i > 0
    r = d["tresorerie"].to_f / d["total_produits"]
    (r / 0.5 * WEIGHTS[:liquidite]).clamp(0, WEIGHTS[:liquidite]).round(1)
  else 0 end

  detail[:autonomie] = if d["subv_sur_produits_pct"]
    a = (100 - d["subv_sur_produits_pct"]) / 100.0
    (a * WEIGHTS[:autonomie]).clamp(0, WEIGHTS[:autonomie]).round(1)
  else WEIGHTS[:autonomie] / 2.0 end

  detail[:gouvernance] = d["cac_certifie"] ? WEIGHTS[:gouvernance] : 0

  total = detail.values.sum.round
  niveau = NIVEAUX.find { |n| total >= n[:min] }[:label]
  [total, niveau, detail]
end

existing = {}
if File.exist?(OUTPUT)
  CSV.foreach(OUTPUT, headers: true) do |row|
    fichier = row["fichier"]
    has_error = row["error"] && !row["error"].empty?
    has_score = row["niveau"] && !row["niveau"].empty?
    existing[fichier] = { ok: has_score && !has_error, row: row }
  end
end

pdfs = Dir["#{PDF_DIR}/*.pdf"].sort
to_process = pdfs.reject { |p| existing[File.basename(p)]&.dig(:ok) }
puts "[info] #{pdfs.size} PDFs total, #{existing.size - to_process.size} déjà OK, #{to_process.size} à (re)traiter"

CSV.open(OUTPUT, "w", write_headers: true,
         headers: %w[fichier siren cloture nom ville total_produits resultat_exploitation
                     resultat_net fonds_propres tresorerie total_bilan subv_pct cac_certifie
                     statut score niveau pts_rent pts_soli pts_liqu pts_auto pts_gouv error]) do |csv|

  pdfs.each_with_index do |pdf, i|
    fichier = File.basename(pdf)

    if existing[fichier]&.dig(:ok)
      csv << existing[fichier][:row].fields
      next
    end

    puts "[#{i+1}/#{pdfs.size}] #{fichier}"
    d = extract(pdf)
    File.write("#{LOG_DIR}/#{fichier}.json", JSON.pretty_generate(d))

    if d["error"] || d[:error]
      csv << [fichier] + Array.new(15) + [(d[:error] || d["error"]).to_s[0,200]]
      sleep SLEEP_BETWEEN
      next
    end

    s, niveau, detail = score(d)
    csv << [
      fichier, d["siren"], d["cloture"], d["nom"], d["ville"],
      d["total_produits"], d["resultat_exploitation"], d["resultat_net"],
      d["fonds_propres"], d["tresorerie"], d["total_bilan"],
      d["subv_sur_produits_pct"], d["cac_certifie"], d["statut"],
      s, niveau,
      detail[:rentabilite], detail[:solidite], detail[:liquidite],
      detail[:autonomie], detail[:gouvernance],
      nil
    ]
    sleep SLEEP_BETWEEN
  end
end

puts "\n[done] -> #{OUTPUT}"
puts "\n=== Distribution des niveaux ==="
data = CSV.read(OUTPUT, headers: true)
data.group_by { |r| r["niveau"] || "ERREUR" }.sort_by { |k, _| k.to_s }.each do |niv, rows|
  pct = (100.0 * rows.size / data.size).round(1)
  puts "  #{niv}: #{rows.size.to_s.rjust(3)} (#{pct}%)"
end
