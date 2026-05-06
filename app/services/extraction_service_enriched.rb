# Extraction enrichie pour le sample v10 (étape 2b ML).
# Reprend ExtractionService::PROMPT et ajoute deux fields non-comptables :
#   - cac_certification_qualite : enum ou null
#   - concentration_financeurs  : float [0,1] ou null
#
# Aucune modification d'ExtractionService ; on duplique le prompt pour
# l'isoler du flow web (qui scorent encore via le prompt original).
class ExtractionServiceEnriched
  PROMPT = <<~PROMPT
    Tu es un expert-comptable spécialisé dans l'analyse financière des associations loi 1901 françaises.
    Analyse ce document comptable (bilan + compte de résultat + annexes éventuelles) et extrais les données suivantes.
    Réponds UNIQUEMENT avec un objet JSON valide, sans texte avant ni après, sans balises markdown.

    Champs comptables (mêmes définitions que d'habitude) :
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

    Champs supplémentaires (v10) :
    - cac_certification_qualite : si un commissaire aux comptes a établi un rapport, indique la qualité de la certification.
        Valeurs autorisées (exactement) :
          "certifie_sans_reserve"             si le CAC certifie sans réserve
          "certifie_avec_reserve"             si le CAC certifie avec réserve
          "refus_certification"               si le CAC refuse de certifier
          "alerte_continuite_exploitation"    si le CAC déclenche la procédure d'alerte sur continuité d'exploitation
        null s'il n'y a pas de CAC ou si la qualité ne peut pas être déterminée avec certitude.
    - concentration_financeurs : si l'annexe contient un détail nominatif des subventions reçues
        (par financeur public : État, collectivités, organismes), calcule la part (entre 0 et 1) du plus
        gros financeur sur le total des subventions publiques.
        null si l'annexe ne donne pas ce détail, ou si la concentration ne peut pas être calculée de façon fiable.
        Ne devine pas : si le détail n'est pas explicitement présent, retourne null.

    Rappel : JSON valide uniquement, pas de texte autour, pas de markdown.
  PROMPT

  ALLOWED_CAC_QUALITE = %w[
    certifie_sans_reserve
    certifie_avec_reserve
    refus_certification
    alerte_continuite_exploitation
  ].freeze

  def initialize(pdf_path)
    @pdf_path = pdf_path
  end

  def call
    client = Anthropic::Client.new(api_key: ENV["ANTHROPIC_API_KEY"])
    pdf_data = Base64.strict_encode64(File.binread(@pdf_path))

    response = client.messages.create(
      model: "claude-sonnet-4-5",
      max_tokens: 1500,
      messages: [
        {
          role: "user",
          content: [
            {
              type: "document",
              source: {
                type: "base64",
                media_type: "application/pdf",
                data: pdf_data
              }
            },
            {
              type: "text",
              text: PROMPT
            }
          ]
        }
      ]
    )

    raw = response.content.first.text.gsub(/\A```json\n?/, "").gsub(/\n?```\z/, "").strip
    parsed = JSON.parse(raw)
    [normalize(parsed), response.usage, nil]
  rescue JSON::ParserError => e
    [nil, nil, "JSON invalide : #{e.message[0..150]}"]
  rescue => e
    [nil, nil, "#{e.class} : #{e.message[0..200]}"]
  end

  def self.normalize_static(parsed)
    new("dummy").send(:normalize, parsed)
  end

  private

  def normalize(parsed)
    q = parsed["cac_certification_qualite"]
    parsed["cac_certification_qualite"] = ALLOWED_CAC_QUALITE.include?(q) ? q : nil

    cf = parsed["concentration_financeurs"]
    parsed["concentration_financeurs"] = if cf.is_a?(Numeric) && cf >= 0 && cf <= 1
                                            cf.to_f
                                         elsif cf.is_a?(String) && cf =~ /\A-?\d+(\.\d+)?\z/
                                            v = cf.to_f
                                            (v >= 0 && v <= 1) ? v : nil
                                         else
                                            nil
                                         end
    parsed
  end
end
