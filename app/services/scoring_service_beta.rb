# Variante β du ScoringService.
# Reprend ScoringService à l'identique pour le calcul du score 0-100, puis
# applique une règle de désalerte « trois sous-scores faibles » :
# si au moins 3 des 5 sous-scores sont en dessous de 40 % de leur poids
# max, le niveau est descendu d'un cran (sauf E, qui reste E).
#
# Le seuil 40 % est choisi pour repérer un déséquilibre structurel
# (plusieurs dimensions financières simultanément dégradées) que le
# score global pondéré peut masquer si une dimension compense une autre.
#
# Aucune modification de ScoringService original.
class ScoringServiceBeta
  WEIGHTS = ScoringService::WEIGHTS
  NIVEAUX = ScoringService::NIVEAUX

  THRESHOLDS = {
    rentabilite: WEIGHTS[:rentabilite] * 0.4, # 12.0
    solidite:    WEIGHTS[:solidite]    * 0.4, # 10.0
    liquidite:   WEIGHTS[:liquidite]   * 0.4, # 8.0
    autonomie:   WEIGHTS[:autonomie]   * 0.4, # 6.0
    gouvernance: WEIGHTS[:gouvernance] * 0.4  # 4.0
  }.freeze

  MIN_FAIBLES = 3

  def initialize(association)
    @a = association
  end

  def call
    base = ScoringService.new(@a).call
    detail = base[:detail]

    faibles = THRESHOLDS.count { |k, t| detail[k].to_f < t }
    niveau_initial = base[:niveau]

    niveau_final = if faibles >= MIN_FAIBLES && niveau_initial != 'E'
      niveau_inferieur(niveau_initial)
    else
      niveau_initial
    end

    info = NIVEAUX.find { |n| n[:label] == niveau_final } || NIVEAUX.last

    {
      score:                  base[:score],
      niveau:                 niveau_final,
      niveau_initial:         niveau_initial,
      niveau_text:            info[:text],
      niveau_color:           info[:color],
      detail:                 detail,
      sous_scores_faibles:    faibles,
      regle_appliquee:        faibles >= MIN_FAIBLES && niveau_initial != 'E'
    }
  end

  private

  DOWN = { 'A' => 'B', 'B' => 'C', 'C' => 'D', 'D' => 'E', 'E' => 'E' }.freeze

  def niveau_inferieur(label)
    DOWN[label] || label
  end
end
