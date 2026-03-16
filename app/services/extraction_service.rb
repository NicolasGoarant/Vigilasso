class ExtractionService
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

  def initialize(pdf_path)
    @pdf_path = pdf_path
  end

  def call
    client = Anthropic::Client.new(api_key: ENV["ANTHROPIC_API_KEY"])
    pdf_data = Base64.strict_encode64(File.binread(@pdf_path))

    response = client.messages.create(
      model: "claude-sonnet-4-5",
      max_tokens: 1024,
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
    JSON.parse(raw)
  rescue JSON::ParserError => e
    { error: "JSON invalide : #{e.message}", raw: raw }
  rescue => e
    { error: "#{e.class} : #{e.message}" }
  end
end
