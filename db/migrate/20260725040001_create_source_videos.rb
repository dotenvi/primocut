class CreateSourceVideos < ActiveRecord::Migration[8.1]
  def change
    create_table :source_videos do |t|
      # The niche this source video belongs to. Set once at submit time and never
      # rewritten (metadata refreshes during the pipeline do not carry it).
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.string :youtube_id, null: false
      t.string :url, null: false
      t.string :title, null: false, default: ""
      t.string :channel, null: false, default: ""
      t.integer :duration_s, null: false, default: 0
      t.string :status, null: false, default: "queued"

      t.timestamps
    end

    add_index :source_videos, :youtube_id, unique: true
  end
end
