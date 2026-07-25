class CreateExports < ActiveRecord::Migration[8.1]
  def change
    create_table :exports do |t|
      # The state of a cut's LATEST export (one row per cut, upserted). An export
      # packages the cut's rendered clips into a deliverable bundle on disk; this
      # row is what the UI polls to learn when the zip is ready. History stays on
      # disk (timestamped package dirs); only the latest paths/state live here.
      t.references :cut, null: false, foreign_key: { on_delete: :cascade },
                   index: { unique: true }
      t.bigint :source_video_id, null: false # denormalized for path building
      # queued -> packaging -> done | error
      t.string :state, null: false, default: "queued"
      t.text :error, null: false, default: ""
      t.string :package_rel_path, null: false, default: "" # relative to exports_dir
      t.string :zip_rel_path, null: false, default: ""
      t.integer :item_count, null: false, default: 0
      t.boolean :skip_master, null: false, default: false
      t.boolean :upscaled, null: false, default: false

      t.timestamps
    end
    add_index :exports, :source_video_id
  end
end
