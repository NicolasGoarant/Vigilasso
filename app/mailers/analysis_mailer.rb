class AnalysisMailer < ApplicationMailer
  default from: "Vigil'Asso <noreply@vigilasso.fr>"

  def save_link(analysis)
    @analysis = analysis
    @url = analyse_url(token: analysis.token)
    mail(
      to: analysis.email,
      subject: "Vigil'Asso — votre analyse de #{analysis.nom || 'l’association'}"
    )
  end
end
