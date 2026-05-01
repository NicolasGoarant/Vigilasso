require "csv"

namespace :bodacc do
  desc "Importe les scores BODACC depuis data/scores_positifs.csv"
  task import: :environment do
    csv_path     = "data/scores_positifs.csv"
    bodacc_path  = "bodacc_associations_dedup.csv"

    bodacc = {}
    CSV.foreach(bodacc_path, headers: true) do |row|
      bodacc[row["siren"]] = {
        date_jugement:    row["date_jugement"],
        nature_jugement:  row["nature_jugement"]
      }
    end

    created = updated = skipped = errors = 0

    CSV.foreach(csv_path, headers: true) do |row|
      next if row["niveau"].nil? || row["niveau"].empty?

      m = row["fichier"].match(/^(\d{9})_(\d{2})(\d{2})(\d{4})\.pdf$/)
      unless m
        puts "[skip] nom invalide: #{row['fichier']}"
        skipped += 1
        next
      end
      siren   = m[1]
      cloture = Date.new(m[4].to_i, m[3].to_i, m[2].to_i)

      meta = bodacc[siren] || {}

      asso = Association.find_or_initialize_by(siren: siren, cloture: cloture)
      action = asso.new_record? ? :create : :update

      asso.assign_attributes(
        nom:                    row["nom"],
        ville:                  row["ville"],
        total_produits:         row["total_produits"]&.to_i,
        resultat_exploitation:  row["resultat_exploitation"]&.to_i,
        resultat_net:           row["resultat_net"]&.to_i,
        fonds_propres:          row["fonds_propres"]&.to_i,
        tresorerie:             row["tresorerie"]&.to_i,
        total_bilan:            row["total_bilan"]&.to_i,
        subv_sur_produits_pct:  row["subv_pct"]&.to_i,
        cac_certifie:           row["cac_certifie"] == "true",
        statut:                 row["statut"],
        defaillance_bodacc:     true,
        date_jugement:          meta[:date_jugement],
        nature_jugement:        meta[:nature_jugement]
      )

      if asso.save
        action == :create ? (created += 1) : (updated += 1)
      else
        puts "[err] #{siren} #{cloture}: #{asso.errors.full_messages.join(', ')}"
        errors += 1
      end
    end

    puts ""
    puts "=== Import BODACC terminé ==="
    puts "  Créés     : #{created}"
    puts "  Mis à jour: #{updated}"
    puts "  Skippés   : #{skipped}"
    puts "  Erreurs   : #{errors}"
    puts ""
    puts "Total Association: #{Association.count} (dont défaillantes: #{Association.defaillantes.count})"
  end
end
