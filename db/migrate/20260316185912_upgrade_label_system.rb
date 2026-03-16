class UpgradeLabelSystem < ActiveRecord::Migration[7.2]
  def change
    remove_column :associations, :label_vigi, :integer
    add_column :associations, :score_vigi, :integer
    add_column :associations, :niveau_vigi, :string, limit: 1
    add_column :associations, :score_detail, :jsonb
  end
end
