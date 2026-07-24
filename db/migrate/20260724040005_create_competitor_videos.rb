class CreateCompetitorVideos < ActiveRecord::Migration[8.1]
  def change
    create_table :competitor_videos do |t|
      t.references :competitor_channel, null: false,
                   foreign_key: { on_delete: :cascade }
      t.string :youtube_video_id, null: false
      t.string :title, null: false, default: ""
      t.datetime :published_at
      t.integer :duration_s, null: false, default: 0
      t.boolean :is_short, null: false, default: false
      t.string :thumbnail_url, null: false, default: ""
      t.string :thumbnail_hash, null: false, default: ""

      # Automatic, deterministic top-comment collection state.
      t.string :comments_state, null: false, default: ""
      t.text :comments_error, null: false, default: ""
      t.datetime :comments_fetched_at

      # Highest outlier band ever EMITTED (anti-flapping guard).
      t.string :last_band_emitted, null: false, default: ""

      t.timestamps
    end

    add_index :competitor_videos, :youtube_video_id, unique: true
  end
end
