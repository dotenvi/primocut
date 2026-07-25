class CreateTopicTriages < ActiveRecord::Migration[8.1]
  def change
    create_table :topic_triages do |t|
      # The user's OPINION about a topic, scoped to the source video and shared
      # across its cuts. Absence of a row means "open"; only "maybe"/"discarded"
      # are ever stored (membership — "in" — is derived from a cut's items, never
      # written here). Regenerating topics drops opinions about vanished topics.
      t.references :source_video, null: false, foreign_key: { on_delete: :cascade }
      t.references :topic, null: false, foreign_key: { on_delete: :cascade }
      t.string :state, null: false

      t.timestamps
    end
    add_index :topic_triages, %i[source_video_id topic_id], unique: true,
              name: "index_topic_triages_uniqueness"
  end
end
