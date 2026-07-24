class CreateVideoEnrichments < ActiveRecord::Migration[8.1]
  def change
    create_table :video_enrichments do |t|
      t.references :competitor_video, null: false,
                   foreign_key: { on_delete: :cascade }
      t.string :kind, null: false # "comment_synthesis"
      t.jsonb :payload, null: false, default: {}
      t.string :content_hash, null: false, default: ""
      t.string :state, null: false, default: "done" # "running" | "done" | "error"
      t.text :error, null: false, default: ""

      t.timestamps
    end

    add_index :video_enrichments, [ :competitor_video_id, :kind ], unique: true
  end
end
