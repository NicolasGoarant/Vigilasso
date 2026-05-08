require "csv"

class PagesController < ApplicationController
  PHASE4_RESULTS_CSV = Rails.root.join("app/assets/fichiers_internes/data/phase4_results.csv")

  def home
  end

  def methodologie
    rows = CSV.read(PHASE4_RESULTS_CSV, headers: true)

    @matrices = {
      recent_cde:  confusion(rows, "recent_niveau",  %w[C D E]),
      recent_de:   confusion(rows, "recent_niveau",  %w[D E]),
      contemp_cde: confusion(rows, "contemp_niveau", %w[C D E]),
      contemp_de:  confusion(rows, "contemp_niveau", %w[D E])
    }

    @sample_size       = @matrices[:recent_cde][:total]
    @temporal_delta_cde = delta_pp(@matrices[:recent_cde], @matrices[:contemp_cde])
    @temporal_delta_de  = delta_pp(@matrices[:recent_de],  @matrices[:contemp_de])
  end

  private

  def confusion(rows, niveau_field, fragile_levels)
    tp = fp = fn_ = tn = skipped = 0
    rows.each do |r|
      niveau = r[niveau_field]
      if niveau.to_s.empty?
        skipped += 1
        next
      end
      expected_fragile  = r["expected_label"] == "fragile"
      predicted_fragile = fragile_levels.include?(niveau)
      case [expected_fragile, predicted_fragile]
      when [true,  true]  then tp  += 1
      when [false, true]  then fp  += 1
      when [true,  false] then fn_ += 1
      when [false, false] then tn  += 1
      end
    end
    total     = tp + fp + fn_ + tn
    precision = (tp + fp).positive? ? tp.to_f / (tp + fp) : 0.0
    recall    = (tp + fn_).positive? ? tp.to_f / (tp + fn_) : 0.0
    f1        = (precision + recall).positive? ? 2 * precision * recall / (precision + recall) : 0.0
    accuracy  = total.positive? ? (tp + tn).to_f / total : 0.0
    {
      tp: tp, fp: fp, fn: fn_, tn: tn,
      total: total, skipped: skipped,
      precision: precision, recall: recall, f1: f1, accuracy: accuracy,
      precision_ci: wilson_ci(tp, tp + fp),
      recall_ci:    wilson_ci(tp, tp + fn_)
    }
  end

  # Intervalle de confiance binomial Wilson 95 %.
  # Retourne [borne_basse, borne_haute] dans [0, 1], ou nil si total nul.
  def wilson_ci(successes, total, z = 1.96)
    return nil if total.zero?
    p_hat   = successes.to_f / total
    denom   = 1.0 + (z**2) / total
    centre  = p_hat + (z**2) / (2 * total)
    margin  = z * Math.sqrt((p_hat * (1 - p_hat) + (z**2) / (4 * total)) / total)
    low     = (centre - margin) / denom
    high    = (centre + margin) / denom
    [[low, 0.0].max, [high, 1.0].min]
  end

  # Écart en points de pourcentage (recent − contemp), positif = recent meilleur
  def delta_pp(recent, contemp)
    {
      precision: ((recent[:precision] - contemp[:precision]) * 100).round(1),
      recall:    ((recent[:recall]    - contemp[:recall])    * 100).round(1),
      f1:        ((recent[:f1]        - contemp[:f1])        * 100).round(1)
    }
  end
end
