class CreateAnalyses < ActiveRecord::Migration[7.2]
  def change
    create_table :analyses do |t|
      t.string  :token,                 null: false
      t.string  :siren
      t.string  :nom
      t.string  :ville
      t.date    :cloture

      t.bigint  :total_produits
      t.bigint  :resultat_exploitation
      t.bigint  :resultat_net
      t.bigint  :fonds_propres
      t.bigint  :tresorerie
      t.bigint  :emprunts
      t.bigint  :total_bilan
      t.integer :subv_sur_produits_pct
      t.integer :masse_sal_pct
      t.integer :fp_bilan_pct
      t.decimal :etp, precision: 8, scale: 2
      t.boolean :cac_certifie, default: false, null: false
      t.integer :statut
      t.text    :notes

      t.integer :score_vigi
      t.string  :niveau_vigi, limit: 1
      t.jsonb   :score_detail
      t.jsonb   :extraction_raw

      t.string    :email
      t.datetime  :expires_at

      t.timestamps
    end

    add_index :analyses, :token, unique: true
    add_index :analyses, :expires_at
  end
end
