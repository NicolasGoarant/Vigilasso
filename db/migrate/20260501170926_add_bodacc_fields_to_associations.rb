class AddBodaccFieldsToAssociations < ActiveRecord::Migration[7.2]
  def change
    add_column :associations, :defaillance_bodacc, :boolean
    add_column :associations, :date_jugement, :date
    add_column :associations, :nature_jugement, :string
  end
end
