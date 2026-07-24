# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_24_040012) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "channel_snapshots", force: :cascade do |t|
    t.datetime "captured_at", null: false
    t.bigint "competitor_channel_id", null: false
    t.datetime "created_at", null: false
    t.bigint "subscribers", default: 0, null: false
    t.bigint "total_views", default: 0, null: false
    t.integer "video_count", default: 0, null: false
    t.index ["competitor_channel_id", "captured_at"], name: "idx_on_competitor_channel_id_captured_at_c33c474561"
    t.index ["competitor_channel_id"], name: "index_channel_snapshots_on_competitor_channel_id"
  end

  create_table "competitor_channels", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "backfill_done", default: 0, null: false
    t.text "backfill_error"
    t.string "backfill_rq_job_id"
    t.string "backfill_state", default: "pending", null: false
    t.integer "backfill_total", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "handle", default: "", null: false
    t.string "title", default: "", null: false
    t.datetime "updated_at", null: false
    t.string "uploads_playlist_id", default: "", null: false
    t.string "youtube_channel_id", null: false
    t.index ["youtube_channel_id"], name: "index_competitor_channels_on_youtube_channel_id", unique: true
  end

  create_table "competitor_videos", force: :cascade do |t|
    t.text "comments_error", default: "", null: false
    t.datetime "comments_fetched_at"
    t.string "comments_state", default: "", null: false
    t.bigint "competitor_channel_id", null: false
    t.datetime "created_at", null: false
    t.integer "duration_s", default: 0, null: false
    t.boolean "is_short", default: false, null: false
    t.string "last_band_emitted", default: "", null: false
    t.datetime "published_at"
    t.string "thumbnail_hash", default: "", null: false
    t.string "thumbnail_url", default: "", null: false
    t.string "title", default: "", null: false
    t.datetime "updated_at", null: false
    t.string "youtube_video_id", null: false
    t.index ["competitor_channel_id"], name: "index_competitor_videos_on_competitor_channel_id"
    t.index ["youtube_video_id"], name: "index_competitor_videos_on_youtube_video_id", unique: true
  end

  create_table "events", force: :cascade do |t|
    t.string "category", null: false
    t.bigint "competitor_channel_id"
    t.bigint "competitor_video_id"
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.datetime "occurred_at", null: false
    t.jsonb "payload", default: {}, null: false
    t.bigint "project_id"
    t.datetime "resolved_at"
    t.datetime "seen_at"
    t.string "severity", default: "info", null: false
    t.bigint "source_video_id"
    t.index ["category", "occurred_at"], name: "index_events_on_category_and_occurred_at", order: { occurred_at: :desc }
  end

  create_table "own_channels", force: :cascade do |t|
    t.string "channel_url", null: false
    t.datetime "created_at", null: false
    t.string "handle", default: "", null: false
    t.bigint "project_id", null: false
    t.string "role"
    t.string "title", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "channel_url"], name: "index_own_channels_on_project_id_and_channel_url", unique: true
    t.index ["project_id"], name: "index_own_channels_on_project_id"
  end

  create_table "packaging_changes", force: :cascade do |t|
    t.bigint "competitor_video_id", null: false
    t.datetime "created_at", null: false
    t.datetime "detected_at", null: false
    t.string "field", null: false
    t.text "new_value", default: "", null: false
    t.text "old_value", default: "", null: false
    t.float "vph_after"
    t.float "vph_before"
    t.index ["competitor_video_id", "detected_at"], name: "index_packaging_changes_on_competitor_video_id_and_detected_at"
    t.index ["competitor_video_id"], name: "index_packaging_changes_on_competitor_video_id"
  end

  create_table "project_channels", force: :cascade do |t|
    t.bigint "competitor_channel_id", null: false
    t.datetime "created_at", null: false
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["competitor_channel_id"], name: "index_project_channels_on_competitor_channel_id"
    t.index ["project_id", "competitor_channel_id"], name: "index_project_channels_uniqueness", unique: true
    t.index ["project_id"], name: "index_project_channels_on_project_id"
  end

  create_table "projects", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.text "description", default: "", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_projects_on_name", unique: true
  end

  create_table "video_attributes", force: :cascade do |t|
    t.jsonb "attrs", default: {}, null: false
    t.bigint "competitor_video_id", null: false
    t.string "content_hash", default: "", null: false
    t.datetime "created_at", null: false
    t.text "error", default: "", null: false
    t.string "source", null: false
    t.string "state", default: "done", null: false
    t.datetime "updated_at", null: false
    t.index ["competitor_video_id", "source"], name: "index_video_attributes_on_competitor_video_id_and_source", unique: true
    t.index ["competitor_video_id"], name: "index_video_attributes_on_competitor_video_id"
  end

  create_table "video_comments", force: :cascade do |t|
    t.string "author", default: "", null: false
    t.string "comment_id", null: false
    t.bigint "competitor_video_id", null: false
    t.datetime "created_at", null: false
    t.datetime "fetched_at", null: false
    t.integer "like_count", default: 0, null: false
    t.text "text", default: "", null: false
    t.index ["competitor_video_id", "comment_id"], name: "index_video_comments_on_competitor_video_id_and_comment_id", unique: true
    t.index ["competitor_video_id"], name: "index_video_comments_on_competitor_video_id"
  end

  create_table "video_enrichments", force: :cascade do |t|
    t.bigint "competitor_video_id", null: false
    t.string "content_hash", default: "", null: false
    t.datetime "created_at", null: false
    t.text "error", default: "", null: false
    t.string "kind", null: false
    t.jsonb "payload", default: {}, null: false
    t.string "state", default: "done", null: false
    t.datetime "updated_at", null: false
    t.index ["competitor_video_id", "kind"], name: "index_video_enrichments_on_competitor_video_id_and_kind", unique: true
    t.index ["competitor_video_id"], name: "index_video_enrichments_on_competitor_video_id"
  end

  create_table "video_snapshots", force: :cascade do |t|
    t.datetime "captured_at", null: false
    t.integer "comments", default: 0, null: false
    t.bigint "competitor_video_id", null: false
    t.datetime "created_at", null: false
    t.integer "likes", default: 0, null: false
    t.bigint "views", default: 0, null: false
    t.index ["competitor_video_id", "captured_at"], name: "index_video_snapshots_on_competitor_video_id_and_captured_at"
    t.index ["competitor_video_id"], name: "index_video_snapshots_on_competitor_video_id"
  end

  add_foreign_key "channel_snapshots", "competitor_channels", on_delete: :cascade
  add_foreign_key "competitor_videos", "competitor_channels", on_delete: :cascade
  add_foreign_key "own_channels", "projects", on_delete: :cascade
  add_foreign_key "packaging_changes", "competitor_videos", on_delete: :cascade
  add_foreign_key "project_channels", "competitor_channels", on_delete: :cascade
  add_foreign_key "project_channels", "projects", on_delete: :cascade
  add_foreign_key "video_attributes", "competitor_videos", on_delete: :cascade
  add_foreign_key "video_comments", "competitor_videos", on_delete: :cascade
  add_foreign_key "video_enrichments", "competitor_videos", on_delete: :cascade
  add_foreign_key "video_snapshots", "competitor_videos", on_delete: :cascade
end
