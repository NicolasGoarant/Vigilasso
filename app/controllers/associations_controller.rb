class AssociationsController < ApplicationController
  before_action :authenticate_user!

  MAX_PDFS = 10

  def index
    @filter = params[:filter] || "all"
    @associations = case @filter
                    when "defaillantes" then Association.defaillantes
                    when "saines"       then Association.saines
                    else                     Association.all
                    end.order(created_at: :desc)

    total = Association.count
    @stats = {
      total: total,
      defaillantes: Association.defaillantes.count,
      deficitaires: @associations.deficit.count,
      non_labellises: @associations.non_labellises.count,
      budget_total: @associations.sum(:total_produits),
      score_moyen: @associations.where.not(score_vigi: nil).average(:score_vigi)&.round || "—"
    }
  end

  def show
    @association = Association.find(params[:id])
  end

  def new
    @association = Association.new
  end

  def create
    pdfs = Array(params[:pdfs]).compact.reject { |f| f.blank? }
    if pdfs.empty?
      redirect_to new_association_path, alert: "Aucun fichier sélectionné." and return
    end
    if pdfs.size > MAX_PDFS
      redirect_to new_association_path, alert: "Maximum #{MAX_PDFS} fichiers par lot." and return
    end
    results = { success: [], errors: [] }
    pdfs.each do |pdf|
      data = ExtractionService.new(pdf.tempfile.path).call
      if data[:error]
        results[:errors] << "#{pdf.original_filename} : #{data[:error]}"
        next
      end
      association = Association.new(
        siren:                  data["siren"],
        nom:                    data["nom"],
        ville:                  data["ville"],
        cloture:                data["cloture"],
        total_produits:         data["total_produits"],
        resultat_exploitation:  data["resultat_exploitation"],
        resultat_net:           data["resultat_net"],
        fonds_propres:          data["fonds_propres"],
        tresorerie:             data["tresorerie"],
        emprunts:               data["emprunts"],
        total_bilan:            data["total_bilan"],
        subv_sur_produits_pct:  data["subv_sur_produits_pct"],
        masse_sal_pct:          data["masse_sal_pct"],
        fp_bilan_pct:           data["fp_bilan_pct"],
        etp:                    data["etp"],
        cac_certifie:           data["cac_certifie"],
        statut:                 data["statut"],
        notes:                  data["notes"],
        extraction_raw:         data
      )
      association.pdf.attach(pdf)
      if association.save
        results[:success] << association.nom
      else
        results[:errors] << "#{pdf.original_filename} : #{association.errors.full_messages.join(', ')}"
      end
    end
    msg_parts = []
    msg_parts << "#{results[:success].size} association(s) importée(s) : #{results[:success].join(', ')}." if results[:success].any?
    msg_parts << "#{results[:errors].size} erreur(s) : #{results[:errors].join(' | ')}" if results[:errors].any?
    if results[:success].any?
      redirect_to associations_path, notice: msg_parts.join(" — ")
    else
      redirect_to new_association_path, alert: msg_parts.join(" — ")
    end
  end

  def update
    @association = Association.find(params[:id])
    if @association.update(association_params)
      redirect_to @association, notice: "Mise à jour enregistrée."
    else
      render :show
    end
  end

  def destroy
    Association.find(params[:id]).destroy
    redirect_to associations_path, notice: "Association supprimée."
  end

  def relancer_extraction
    @association = Association.find(params[:id])
    tmp = Tempfile.new(["pdf", ".pdf"])
    tmp.binmode
    tmp.write(@association.pdf.download)
    tmp.rewind
    data = ExtractionService.new(tmp.path).call
    tmp.close
    if data[:error]
      redirect_to @association, alert: "Erreur : #{data[:error]}"
    else
      @association.update(extraction_raw: data, notes: data["notes"])
      redirect_to @association, notice: "Extraction relancée."
    end
  end

  def export
    associations = Association.all.order(:nom)
    csv = CSV.generate(headers: true) do |csv|
      csv << %w[siren nom ville cloture total_produits resultat_exploitation
                resultat_net fonds_propres tresorerie emprunts total_bilan
                subv_sur_produits_pct masse_sal_pct fp_bilan_pct etp
                cac_certifie statut score_vigi niveau_vigi notes]
      associations.each do |a|
        csv << [a.siren, a.nom, a.ville, a.cloture, a.total_produits,
                a.resultat_exploitation, a.resultat_net, a.fonds_propres,
                a.tresorerie, a.emprunts, a.total_bilan, a.subv_sur_produits_pct,
                a.masse_sal_pct, a.fp_bilan_pct, a.etp, a.cac_certifie,
                a.statut, a.score_vigi, a.niveau_vigi, a.notes]
      end
    end
    send_data csv, filename: "vigilasso_#{Date.today}.csv", type: "text/csv"
  end

  private

  def association_params
    params.require(:association).permit(:notes, :statut)
  end
end
