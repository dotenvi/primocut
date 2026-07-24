class CreateEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :events do |t|
      t.string :category, null: false # "niche" | "ops"
      t.string :event_type, null: false # `type` is reserved by Rails (STI)
      t.string :severity, null: false, default: "info" # "info" | "error"

      # Append-only log: subjects are nullable bigint soft-refs, NO foreign keys,
      # so a recorded fact outlives the deletion of any subject it references.
      t.bigint :project_id
      t.bigint :competitor_channel_id
      t.bigint :competitor_video_id
      t.bigint :source_video_id # bare bigint; its table arrives in Phase 1b

      t.datetime :occurred_at, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :seen_at
      t.datetime :resolved_at

      t.datetime :created_at, null: false
    end

    # The Radar feed is WHERE category=? ORDER BY occurred_at DESC LIMIT n.
    add_index :events, [ :category, :occurred_at ], order: { occurred_at: :desc }
  end
end
