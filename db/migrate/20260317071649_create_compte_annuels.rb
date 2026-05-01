class CreateCompteAnnuels < ActiveRecord::Migration[7.2]
  def change
    create_table :compte_annuels do |t|
      t.string :siren
      t.string :jo_id
      t.date :date_cloture
      t.integer :exercice
      t.string :pdf_path
      t.string :statut
      t.integer :total_bilan
      t.integer :total_actif_immobilise
      t.integer :total_actif_circulant
      t.integer :fonds_propres
      t.integer :dettes_total
      t.integer :provisions
      t.integer :produits_exploitation
      t.integer :charges_exploitation
      t.integer :resultat_exploitation
      t.integer :produits_financiers
      t.integer :charges_financieres
      t.integer :resultat_financier
      t.integer :resultat_exceptionnel
      t.integer :resultat_net
      t.integer :subventions
      t.integer :masse_salariale
      t.integer :charges_sociales
      t.decimal :effectif_etp
      t.text :raw_json
      t.text :erreur

      t.timestamps
    end
  end
end
