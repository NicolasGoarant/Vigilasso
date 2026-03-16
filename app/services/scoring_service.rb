class ScoringService
  # Pondérations (total = 100 pts)
  WEIGHTS = {
    rentabilite:  30,
    solidite:     25,
    liquidite:    20,
    autonomie:    15,
    gouvernance:  10
  }.freeze

  NIVEAUX = [
    { label: "A", min: 80, color: "#1a7a4a", text: "Situation saine" },
    { label: "B", min: 60, color: "#4caf7d", text: "Situation satisfaisante" },
    { label: "C", min: 40, color: "#f5a623", text: "Vigilance recommandée" },
    { label: "D", min: 20, color: "#e8622a", text: "Situation préoccupante" },
    { label: "E", min:  0, color: "#c0392b", text: "Risque élevé" }
  ].freeze

  def initialize(association)
    @a = association
  end

  def call
    detail = compute_detail
    score  = detail.values.sum.round
    niveau = niveau_for(score)

    {
      score:        score,
      niveau:       niveau[:label],
      niveau_text:  niveau[:text],
      niveau_color: niveau[:color],
      detail:       detail
    }
  end

  def self.niveau_info(label)
    NIVEAUX.find { |n| n[:label] == label } || NIVEAUX.last
  end

  private

  def compute_detail
    detail = {}

    # 1. Rentabilité courante (résultat exploit / total produits)
    detail[:rentabilite] = if @a.total_produits.to_i > 0
      ratio = @a.resultat_exploitation.to_f / @a.total_produits
      # ratio entre -0.3 et +0.3 → score 0 à 30
      pts = ((ratio + 0.3) / 0.6 * WEIGHTS[:rentabilite]).clamp(0, WEIGHTS[:rentabilite])
      pts.round(1)
    else
      0
    end

    # 2. Solidité du bilan (fonds propres / total bilan)
    detail[:solidite] = if @a.total_bilan.to_i > 0
      ratio = @a.fonds_propres.to_f / @a.total_bilan
      # ratio entre 0 et 0.8 → score 0 à 25
      pts = (ratio / 0.8 * WEIGHTS[:solidite]).clamp(0, WEIGHTS[:solidite])
      pts.round(1)
    else
      0
    end

    # 3. Liquidité (trésorerie / total produits)
    detail[:liquidite] = if @a.total_produits.to_i > 0
      ratio = @a.tresorerie.to_f / @a.total_produits
      # ratio entre 0 et 0.5 → score 0 à 20
      pts = (ratio / 0.5 * WEIGHTS[:liquidite]).clamp(0, WEIGHTS[:liquidite])
      pts.round(1)
    else
      0
    end

    # 4. Autonomie financière (1 - subventions / produits)
    detail[:autonomie] = if @a.subv_sur_produits_pct
      autonomie = (100 - @a.subv_sur_produits_pct) / 100.0
      pts = (autonomie * WEIGHTS[:autonomie]).clamp(0, WEIGHTS[:autonomie])
      pts.round(1)
    else
      WEIGHTS[:autonomie] / 2.0
    end

    # 5. Gouvernance (CAC certifié)
    detail[:gouvernance] = @a.cac_certifie? ? WEIGHTS[:gouvernance] : 0

    detail
  end

  def niveau_for(score)
    NIVEAUX.find { |n| score >= n[:min] } || NIVEAUX.last
  end
end
