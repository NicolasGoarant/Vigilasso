class Association < ApplicationRecord
  has_one_attached :pdf

  enum :statut, {
    excedent: 0,
    deficit: 1,
    ambigu: 2
  }

  validates :nom, presence: true
  validates :statut, presence: true
  validates :siren, format: { with: /\A\d{9}\z/, message: "doit faire 9 chiffres" }, allow_blank: true
  validates :siren, uniqueness: { scope: :cloture, message: "déjà importé pour cette clôture" }, allow_blank: true

  scope :deficitaires,    -> { where(statut: :deficit) }
  scope :non_labellises,  -> { where(niveau_vigi: nil) }
  scope :avec_pdf,        -> { joins(:pdf_attachment) }
  scope :defaillantes,    -> { where(defaillance_bodacc: true) }
  scope :saines,          -> { where(defaillance_bodacc: [false, nil]) }

  before_save :calculer_score

  def niveau_info
    ScoringService.niveau_info(niveau_vigi)
  end

  private

  def calculer_score
    result = ScoringService.new(self).call
    self.score_vigi    = result[:score]
    self.niveau_vigi   = result[:niveau]
    self.score_detail  = result[:detail]
  end
end
