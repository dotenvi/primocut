class CreatePackagingChanges < ActiveRecord::Migration[8.1]
  def change
    create_table :packaging_changes do |t|
      t.references :competitor_video, null: false,
                   foreign_key: { on_delete: :cascade }
      t.string :field, null: false # "title" | "thumbnail"
      t.text :old_value, null: false, default: ""
      t.text :new_value, null: false, default: ""
      t.datetime :detected_at, null: false
      # Filled by the metrics step; NULL at collection time.
      t.float :vph_before
      t.float :vph_after

      t.datetime :created_at, null: false
    end

    add_index :packaging_changes, [ :competitor_video_id, :detected_at ]
  end
end
