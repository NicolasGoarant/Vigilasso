class CreateAssociations < ActiveRecord::Migration[7.2]
  def change
    create_table :associations do |t|
      t.string :siren
      t.string :nom
      t.string :ville
      t.date :cloture
      t.integer :total_produits
      t.integer :resultat_exploitation
      t.integer :resultat_net
      t.integer :fonds_propres
      t.integer :tresorerie
      t.integer :emprunts
      t.integer :total_bilan
      t.integer :subv_sur_produits_pct
      t.integer :masse_sal_pct
      t.integer :fp_bilan_pct
      t.decimal :etp
      t.boolean :cac_certifie
      t.integer :statut
      t.integer :label_vigi
      t.text :notes
      t.jsonb :extraction_raw

      t.timestamps
    end
  end
end
