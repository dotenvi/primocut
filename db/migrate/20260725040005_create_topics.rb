class CreateTopics < ActiveRecord::Migration[8.1]
  def change
    create_table :topics do |t|
      # The LLM-selected segments of a source video's transcript. Regenerating a
      # source video's topics replaces the whole set, so the row cascades.
      t.references :source_video, null: false, foreign_key: { on_delete: :cascade }
      t.integer :ordinal, null: false, default: 0
      t.string :title, null: false, default: ""
      t.text :summary, null: false, default: ""
      # `start`/`end` in the PoC — renamed to the project's `_s` convention (also
      # avoids the `end` keyword clash on the AR attribute).
      t.float :start_s, null: false, default: 0.0
      t.float :end_s, null: false, default: 0.0
      t.float :score, null: false, default: 0.0

      t.timestamps
    end
  end
end
