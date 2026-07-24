class CreateVideoSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :video_snapshots do |t|
      t.references :competitor_video, null: false,
                   foreign_key: { on_delete: :cascade }
      t.datetime :captured_at, null: false
      t.bigint :views, null: false, default: 0
      t.integer :likes, null: false, default: 0
      t.integer :comments, null: false, default: 0

      # Immutable series: insertion time only, never updated.
      t.datetime :created_at, null: false
    end

    add_index :video_snapshots, [ :competitor_video_id, :captured_at ]
  end
end
