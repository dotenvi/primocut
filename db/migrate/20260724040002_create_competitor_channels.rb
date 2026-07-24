class CreateCompetitorChannels < ActiveRecord::Migration[8.1]
  def change
    create_table :competitor_channels do |t|
      t.string :youtube_channel_id, null: false
      t.string :handle, null: false, default: ""
      t.string :title, null: false, default: ""
      t.string :uploads_playlist_id, null: false, default: ""
      t.boolean :active, null: false, default: true

      # Backfill progress, polled like the video pipeline (once per channel).
      t.string :backfill_state, null: false, default: "pending"
      t.integer :backfill_done, null: false, default: 0
      t.integer :backfill_total, null: false, default: 0
      t.text :backfill_error
      t.string :backfill_rq_job_id

      t.timestamps
    end

    add_index :competitor_channels, :youtube_channel_id, unique: true
  end
end
