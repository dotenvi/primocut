class CreateChannelSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :channel_snapshots do |t|
      t.references :competitor_channel, null: false,
                   foreign_key: { on_delete: :cascade }
      t.datetime :captured_at, null: false
      t.bigint :subscribers, null: false, default: 0
      t.bigint :total_views, null: false, default: 0
      t.integer :video_count, null: false, default: 0

      # Immutable series: insertion time only, never updated.
      t.datetime :created_at, null: false
    end

    add_index :channel_snapshots, [ :competitor_channel_id, :captured_at ]
  end
end
