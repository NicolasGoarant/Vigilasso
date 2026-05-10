require "net/http"
require "uri"
require "json"

class LlmCommentaryService
  MODEL       = "claude-haiku-4-5-20251001"
  MAX_TOKENS  = 1200
  TIMEOUT_SEC = 15
  API_URL     = "https://api.anthropic.com/v1/messages"

  SOUS_SCORE_MAX = {
    "rentabilite" => 30, "solidite" => 25, "liquidite" => 20, "autonomie" => 15, "gouvernance" => 10
  }.freeze

  def initialize(analysis)
    @analysis = analysis
  end

  def call
    api_key = ENV["ANTHROPIC_API_KEY"]
    return nil if api_key.blank?

    uri  = URI(API_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.read_timeout = TIMEOUT_SEC
    http.open_timeout = TIMEOUT_SEC

    req = Net::HTTP::Post.new(uri.path, {
      "Content-Type"      => "application/json",
      "x-api-key"         => api_key,
      "anthropic-version" => "2023-06-01"
    })
    req.body = {
      model:      MODEL,
      max_tokens: MAX_TOKENS,
      messages:   [{ role: "user", content: build_prompt }]
    }.to_json

    res = http.request(req)
    unless res.is_a?(Net::HTTPSuccess)
      Rails.logger.warn "[LlmCommentaryService] API #{res.code}: #{res.body.to_s[0..200]}"
      return nil
    end

    text = JSON.parse(res.body).dig("content", 0, "text").to_s.strip
    text = text.gsub(/\A```(?:json)?\n?/, "").gsub(/\n?```\z/, "").strip

    parsed = JSON.parse(text)
    return nil unless parsed.is_a?(Hash) && parsed["resume"].present?
    parsed
  rescue JSON::ParserError => e
    Rails.logger.warn "[LlmCommentaryService] JSON invalide: #{e.message} | #{text&.first(200)}"
    nil
  rescue => e
    Rails.logger.warn "[LlmCommentaryService] #{e.class}: #{e.message}"
    nil
  end

  private

  def build_prompt
    a = @analysis
    detail = a.score_detail || {}
    niveau = a.niveau_vigi || "E"
    niveau_text = ScoringService.niveau_info(niveau)[:text]

    fmt = ->(n) { n.nil? ? "n/a" : ActiveSupport::NumberHelper.number_to_delimited(n.to_i, delimiter: " ") }

    <<~PROMPT
      Tu es un analyste financier spécialisé dans le secteur associatif loi 1901. Analyse cette association et produis un commentaire structuré en JSON.

      Nom : #{a.nom.presence || 'Non renseigné'}
      Niveau Vigil'Asso : #{niveau} (#{niveau_text})
      Score global : #{a.score_vigi}/100

      Sous-scores (sur leur maximum) :
      - Rentabilité : #{detail['rentabilite'].to_f.round(1)}/30
      - Solidité du bilan : #{detail['solidite'].to_f.round(1)}/25
      - Liquidité : #{detail['liquidite'].to_f.round(1)}/20
      - Autonomie financière : #{detail['autonomie'].to_f.round(1)}/15
      - Gouvernance : #{detail['gouvernance'].to_f.round(1)}/10

      Chiffres financiers clés :
      - Total produits : #{fmt.call(a.total_produits)} €
      - Résultat net : #{fmt.call(a.resultat_net)} €
      - Résultat d'exploitation : #{fmt.call(a.resultat_exploitation)} €
      - Fonds propres : #{fmt.call(a.fonds_propres)} €
      - Trésorerie : #{fmt.call(a.tresorerie)} €
      - Subventions : #{a.subv_sur_produits_pct || 'n/a'}% des produits
      - CAC certifié : #{a.cac_certifie? ? 'oui' : 'non'}

      Note d'extraction préalable : #{a.notes.presence || 'aucune'}

      Réponds UNIQUEMENT avec un JSON valide selon ce schéma exact :

      {
        "resume": "1-2 phrases résumant la situation globale, en français accessible, sans jargon",
        "forces": [
          {"titre": "Titre court (3-5 mots)", "detail": "Phrase d'explication concrète avec chiffres clés"}
        ],
        "vigilances": [
          {"titre": "Titre court (3-5 mots)", "detail": "Phrase d'explication avec implication concrète"}
        ],
        "recommandations": [
          {"horizon": "court terme ou moyen terme", "action": "Action concrète recommandée"}
        ],
        "orientation": "saine" ou "à surveiller" ou "à examiner en priorité"
      }

      Règles :
      - 1 à 3 forces (uniquement les vraies forces, sous-scores ≥ 70% du max)
      - 1 à 4 vigilances (sous-scores < 50% du max et notes d'extraction problématiques)
      - 1 à 3 recommandations actionnables, distinguant court terme et moyen terme
      - Pas de jargon comptable. Utilise des qualificatifs comme "très solide", "fragile", "à renforcer"
      - Cite les chiffres clés (montants en euros) quand ils sont significatifs
      - JSON strictement valide, pas de markdown, pas de préambule
    PROMPT
  end
end
