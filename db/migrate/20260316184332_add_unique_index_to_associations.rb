class AddUniqueIndexToAssociations < ActiveRecord::Migration[7.2]
  def change
    add_index :associations, [:siren, :cloture], unique: true, name: "index_associations_on_siren_and_cloture"
  end
end
