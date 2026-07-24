class CreateVideoAttributes < ActiveRecord::Migration[8.1]
  def change
    create_table :video_attributes do |t|
      t.references :competitor_video, null: false,
                   foreign_key: { on_delete: :cascade }
      t.string :source, null: false # "syntactic" | "title_llm" | "thumbnail_llm"
      t.jsonb :attrs, null: false, default: {} # `attributes` is reserved by AR
      t.string :content_hash, null: false, default: ""
      t.string :state, null: false, default: "done" # "running" | "done" | "error"
      t.text :error, null: false, default: ""

      t.timestamps
    end

    add_index :video_attributes, [ :competitor_video_id, :source ], unique: true
  end
end
