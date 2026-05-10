require "net/http"
require "uri"
require "json"

class LlmCommentaryService
  MODEL       = "claude-haiku-4-5-20251001"
  MAX_TOKENS  = 500
  TIMEOUT_SEC = 10
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
    text.presence
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

    pct = ->(key) {
      max = SOUS_SCORE_MAX[key]
      val = detail[key].to_f
      max.to_i.zero? ? 0 : (val / max * 100).round
    }

    fmt = ->(n) { n.nil? ? "n/a" : ActiveSupport::NumberHelper.number_to_delimited(n.to_i, delimiter: " ") }

    <<~PROMPT
      Tu es un analyste financier spécialisé dans le secteur associatif loi 1901. Une association vient d'être analysée par Vigil'Asso. Voici les données :

      Nom : #{a.nom.presence || 'Non renseigné'}
      Niveau attribué : #{niveau} (#{niveau_text})
      Score global : #{a.score_vigi}/100

      Sous-scores (sur leur maximum) :
      - Rentabilité : #{detail['rentabilite'].to_f.round(1)}/30 (#{pct.call('rentabilite')}%)
      - Solidité du bilan : #{detail['solidite'].to_f.round(1)}/25 (#{pct.call('solidite')}%)
      - Liquidité : #{detail['liquidite'].to_f.round(1)}/20 (#{pct.call('liquidite')}%)
      - Autonomie financière : #{detail['autonomie'].to_f.round(1)}/15 (#{pct.call('autonomie')}%)
      - Gouvernance : #{detail['gouvernance'].to_f.round(1)}/10 (#{pct.call('gouvernance')}%)

      Chiffres financiers clés :
      - Total produits : #{fmt.call(a.total_produits)} €
      - Résultat net : #{fmt.call(a.resultat_net)} €
      - Fonds propres : #{fmt.call(a.fonds_propres)} €
      - Trésorerie : #{fmt.call(a.tresorerie)} €
      - Subventions : #{a.subv_sur_produits_pct || 'n/a'}% des produits
      - CAC certifié : #{a.cac_certifie? ? 'oui' : 'non'}

      Note d'extraction (analyse qualitative préalable) : #{a.notes.presence || 'aucune'}

      Rédige un commentaire de 4 à 6 phrases pour un agent de collectivité ou un président d'association, qui :
      1. Reformule en français accessible le score global
      2. Identifie nommément les 1 à 3 forces principales (les sous-scores ≥ 70% du max)
      3. Identifie nommément les 1 à 3 points de vigilance (les sous-scores < 50% du max), en expliquant brièvement les implications concrètes
      4. Conclut par une orientation claire (situation à examiner en priorité, à surveiller, ou globalement saine)

      Évite les pourcentages techniques. Utilise plutôt des qualificatifs ("très solide", "fragile", "à renforcer"). Pas de jargon comptable. Sois direct et utile.

      Réponds UNIQUEMENT par le texte du commentaire, sans préambule ni mise en forme markdown.
    PROMPT
  end
end
