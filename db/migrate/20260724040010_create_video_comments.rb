class CreateVideoComments < ActiveRecord::Migration[8.1]
  def change
    create_table :video_comments do |t|
      t.references :competitor_video, null: false,
                   foreign_key: { on_delete: :cascade }
      t.string :comment_id, null: false
      t.text :text, null: false, default: ""
      t.integer :like_count, null: false, default: 0
      t.string :author, null: false, default: ""
      t.datetime :fetched_at, null: false

      t.datetime :created_at, null: false
    end

    add_index :video_comments, [ :competitor_video_id, :comment_id ], unique: true
  end
end
