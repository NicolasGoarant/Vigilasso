class AddCommentaryLlmToAnalyses < ActiveRecord::Migration[7.2]
  def change
    add_column :analyses, :commentary_llm, :text
  end
end
