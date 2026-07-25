class CreateClips < ActiveRecord::Migration[8.1]
  def change
    create_table :clips do |t|
      # A rendered clip: one MP4 deliverable per cut item (H.264 + AAC, original
      # resolution), from the section download + FFmpeg re-encode. 1:1 with its
      # cut item — removing the item takes the clip row (and file) with it.
      t.references :cut_item, null: false, foreign_key: { on_delete: :cascade },
                   index: { unique: true }
      # Denormalized so the flat file layout (<video>/<cut>/NNN-slug.mp4) and the
      # pay-once cache lookups need no joins. Plain columns, not associations.
      t.bigint :source_video_id, null: false
      t.bigint :cut_id, null: false
      t.integer :position, null: false, default: 0
      t.string :filename, null: false, default: ""
      t.string :rel_path, null: false, default: ""
      # queued -> downloading_section -> [aligning] -> cutting -> done | error
      t.string :state, null: false, default: "queued"
      t.text :error, null: false, default: ""
      t.string :encode_profile, null: false, default: "" # requested
      t.string :encoder_used, null: false, default: ""    # effective
      t.string :params_hash, null: false, default: ""     # pay-once cache key
      t.float :padding_s, null: false, default: 0.0
      # Requested bounds (the cut item's range) vs. the EFFECTIVE window actually
      # encoded — the surgical WhisperX pass can snap the cut to a word edge, and
      # the export SRT/manifest must reflect what the MP4 really contains.
      t.float :start_s, null: false, default: 0.0
      t.float :end_s, null: false, default: 0.0
      t.float :render_start_s, null: false, default: 0.0
      t.float :render_end_s, null: false, default: 0.0
      t.bigint :size_bytes, null: false, default: 0
      t.float :duration_s, null: false, default: 0.0

      t.timestamps
    end
    add_index :clips, :source_video_id
    add_index :clips, :cut_id
  end
end
