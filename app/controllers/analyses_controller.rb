class AnalysesController < ApplicationController
  protect_from_forgery with: :exception, except: [:create, :save]

  def new
    @analysis = Analysis.new
  end

  def create
    pdf = params[:pdf]
    return render json: { error: "Aucun fichier sélectionné." }, status: :unprocessable_entity if pdf.blank?
    return render json: { error: "Le fichier doit être un PDF." }, status: :unprocessable_entity unless pdf.content_type == "application/pdf"

    data = ExtractionService.new(pdf.tempfile.path).call
    if data.is_a?(Hash) && data[:error]
      return render json: { error: "Erreur d'extraction : #{data[:error]}" }, status: :unprocessable_entity
    end

    analysis = Analysis.new(
      siren:                 data["siren"],
      nom:                   data["nom"],
      ville:                 data["ville"],
      cloture:               data["cloture"],
      total_produits:        data["total_produits"],
      resultat_exploitation: data["resultat_exploitation"],
      resultat_net:          data["resultat_net"],
      fonds_propres:         data["fonds_propres"],
      tresorerie:            data["tresorerie"],
      emprunts:              data["emprunts"],
      total_bilan:           data["total_bilan"],
      subv_sur_produits_pct: data["subv_sur_produits_pct"],
      masse_sal_pct:         data["masse_sal_pct"],
      fp_bilan_pct:          data["fp_bilan_pct"],
      etp:                   data["etp"],
      cac_certifie:          data["cac_certifie"] || false,
      statut:                data["statut"],
      notes:                 data["notes"],
      extraction_raw:        data
    )

    if analysis.save
      render json: { token: analysis.token, redirect: analyse_path(token: analysis.token) }
    else
      render json: { error: analysis.errors.full_messages.join(", ") }, status: :unprocessable_entity
    end
  ensure
    pdf.tempfile.unlink if pdf.respond_to?(:tempfile) && pdf.tempfile.respond_to?(:unlink) && File.exist?(pdf.tempfile.path)
  end

  def show
    @analysis = Analysis.find_by(token: params[:token])
    if @analysis.nil?
      redirect_to analyser_path, alert: "Cette analyse n'existe pas ou a expiré. Vous pouvez en lancer une nouvelle." and return
    end
    if @analysis.expiree?
      redirect_to analyser_path, alert: "Cette analyse a expiré. Vous pouvez en lancer une nouvelle." and return
    end
  end

  def save
    @analysis = Analysis.find_by(token: params[:token])
    if @analysis.nil?
      return render json: { error: "Analyse introuvable." }, status: :not_found
    end

    email = params[:email].to_s.strip.downcase
    if email !~ URI::MailTo::EMAIL_REGEXP
      return render json: { error: "Adresse email invalide." }, status: :unprocessable_entity
    end

    @analysis.update!(email: email, expires_at: nil)
    AnalysisMailer.save_link(@analysis).deliver_later
    render json: { ok: true, message: "Lien envoyé à #{email}." }
  end
end
