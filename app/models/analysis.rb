class Analysis < ApplicationRecord
  enum :statut, { excedent: 0, deficit: 1, ambigu: 2 }

  before_validation :ensure_token, on: :create
  before_validation :ensure_expires_at, on: :create
  before_save :calculer_score

  validates :token, presence: true, uniqueness: true

  scope :anonymes,    -> { where.not(expires_at: nil) }
  scope :sauvegardees, -> { where(expires_at: nil) }
  scope :expirees,    -> { where("expires_at IS NOT NULL AND expires_at < ?", Time.current) }

  def to_param
    token
  end

  def anonyme?
    expires_at.present?
  end

  def sauvegardee?
    email.present? && expires_at.nil?
  end

  def expiree?
    expires_at.present? && expires_at < Time.current
  end

  def cac_certifie?
    cac_certifie
  end

  def niveau_info
    ScoringService.niveau_info(niveau_vigi)
  end

  private

  def ensure_token
    return if token.present?
    loop do
      candidate = SecureRandom.urlsafe_base64(16)
      unless self.class.exists?(token: candidate)
        self.token = candidate
        break
      end
    end
  end

  def ensure_expires_at
    self.expires_at ||= 24.hours.from_now if email.blank?
  end

  def calculer_score
    return unless total_produits.present? || total_bilan.present?
    result = ScoringService.new(self).call
    self.score_vigi   = result[:score]
    self.niveau_vigi  = result[:niveau]
    self.score_detail = result[:detail]
  end
end
