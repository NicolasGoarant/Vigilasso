# Extraction enrichie pour le test α (analyse FP CRC).
# Reprend ExtractionService::PROMPT et ajoute deux fields ciblés sur les
# causes typiques des faux positifs identifiées dans ml/FP_ANALYSIS_v1.md :
#   - fonds_dedies_pct  : float [0,1] ou null
#   - secteur_atypique  : enum + justification
#
# Aucune modification d'ExtractionService ni d'ExtractionServiceEnriched.
class ExtractionServiceAlpha
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

    Champs supplémentaires (test α) :
    - fonds_dedies_pct : dans les annexes des comptes, identifie tous les éléments qui constituent
        des fonds dédiés ou ressources affectées :
          * compte 19 du plan comptable associatif (« Fonds dédiés »)
          * subventions reçues mais affectées à un projet non encore réalisé
          * dons et legs avec affectation par le donateur
          * réserves projet votées par le conseil d'administration
        Calcule le ratio : (montant total de ces éléments) / (fonds propres comptables totaux),
        sous forme de float entre 0 et 1.
        Si l'information n'est pas explicitement présente dans les annexes, retourne null.
        Ne pas inférer ; ne pas estimer ; ne pas extrapoler depuis le seul libellé d'un poste.
    - secteur_atypique : évalue si l'association a un modèle économique atypique.
        Catégorise STRICTEMENT parmi :
          "standard"           subventions + cotisations + activités classiques
          "fondation"          association ou fondation à dotation, revenus du capital structurels
          "quasi_lucratif"     activité commerciale dominante (ventes, prestations majoritaires)
          "mecenat_dominant"   plus de 70 % des ressources proviennent de mécénat privé
          "autre_atypique"     autre profil non standard (ex : office de tourisme adossé à EPCI,
                               scène nationale, école d'enseignement supérieur, festival événementiel)
    - secteur_atypique_justification : une phrase concise expliquant le choix de la catégorie ci-dessus.

    Rappel : JSON valide uniquement, pas de texte autour, pas de markdown.
  PROMPT

  ALLOWED_SECTEUR = %w[
    standard
    fondation
    quasi_lucratif
    mecenat_dominant
    autre_atypique
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
    fd = parsed["fonds_dedies_pct"]
    parsed["fonds_dedies_pct"] = if fd.is_a?(Numeric) && fd >= 0 && fd <= 1
                                   fd.to_f
                                 elsif fd.is_a?(String) && fd =~ /\A-?\d+(\.\d+)?\z/
                                   v = fd.to_f
                                   (v >= 0 && v <= 1) ? v : nil
                                 else
                                   nil
                                 end

    s = parsed["secteur_atypique"]
    parsed["secteur_atypique"] = ALLOWED_SECTEUR.include?(s) ? s : nil
    parsed["secteur_atypique_justification"] = parsed["secteur_atypique_justification"].to_s[0..400]
    parsed
  end
end
