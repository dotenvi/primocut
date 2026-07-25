class CreateCutItems < ActiveRecord::Migration[8.1]
  def change
    create_table :cut_items do |t|
      # One ordered slot of a cut: a topic OR a manual time range. Every item
      # stores its OWN [start_s, end_s] — snapshotted from the topic for a topic
      # item. `topic_id` is nullify (not cascade): regenerating a source video's
      # topics must not silently drop items from a composition, so a topic item
      # degrades into a preserved manual range instead of disappearing.
      t.references :cut, null: false, foreign_key: { on_delete: :cascade }
      t.references :topic, null: true, foreign_key: { on_delete: :nullify }
      t.integer :position, null: false, default: 0
      t.float :start_s, null: false, default: 0.0
      t.float :end_s, null: false, default: 0.0

      t.timestamps
    end
    add_index :cut_items, %i[cut_id position], name: "index_cut_items_on_cut_id_and_position"
  end
end
