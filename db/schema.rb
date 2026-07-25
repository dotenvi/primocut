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

ActiveRecord::Schema[8.1].define(version: 2026_07_25_040012) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "audience_matches", force: :cascade do |t|
    t.string "content_hash", default: "", null: false
    t.datetime "created_at", null: false
    t.text "error", default: "", null: false
    t.jsonb "payload", default: {}, null: false
    t.bigint "source_video_id", null: false
    t.string "state", default: "done", null: false
    t.datetime "updated_at", null: false
    t.index ["source_video_id"], name: "index_audience_matches_on_source_video_id", unique: true
  end

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

  create_table "chat_signals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "peaks", default: [], null: false
    t.jsonb "per_minute", default: [], null: false
    t.bigint "source_video_id", null: false
    t.datetime "updated_at", null: false
    t.index ["source_video_id"], name: "index_chat_signals_on_source_video_id", unique: true
  end

  create_table "clips", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "cut_id", null: false
    t.bigint "cut_item_id", null: false
    t.float "duration_s", default: 0.0, null: false
    t.string "encode_profile", default: "", null: false
    t.string "encoder_used", default: "", null: false
    t.float "end_s", default: 0.0, null: false
    t.text "error", default: "", null: false
    t.string "filename", default: "", null: false
    t.float "padding_s", default: 0.0, null: false
    t.string "params_hash", default: "", null: false
    t.integer "position", default: 0, null: false
    t.string "rel_path", default: "", null: false
    t.float "render_end_s", default: 0.0, null: false
    t.float "render_start_s", default: 0.0, null: false
    t.bigint "size_bytes", default: 0, null: false
    t.bigint "source_video_id", null: false
    t.float "start_s", default: 0.0, null: false
    t.string "state", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.index ["cut_id"], name: "index_clips_on_cut_id"
    t.index ["cut_item_id"], name: "index_clips_on_cut_item_id", unique: true
    t.index ["source_video_id"], name: "index_clips_on_source_video_id"
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

  create_table "cut_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "cut_id", null: false
    t.float "end_s", default: 0.0, null: false
    t.integer "position", default: 0, null: false
    t.float "start_s", default: 0.0, null: false
    t.bigint "topic_id"
    t.datetime "updated_at", null: false
    t.index ["cut_id", "position"], name: "index_cut_items_on_cut_id_and_position"
    t.index ["cut_id"], name: "index_cut_items_on_cut_id"
    t.index ["topic_id"], name: "index_cut_items_on_topic_id"
  end

  create_table "cut_packagings", force: :cascade do |t|
    t.string "content_hash", default: "", null: false
    t.datetime "created_at", null: false
    t.bigint "cut_id", null: false
    t.bigint "cut_item_id", null: false
    t.text "error", default: "", null: false
    t.string "kind", null: false
    t.jsonb "payload", default: {}, null: false
    t.string "state", default: "done", null: false
    t.datetime "updated_at", null: false
    t.index ["cut_id"], name: "index_cut_packagings_on_cut_id"
    t.index ["cut_item_id", "kind"], name: "index_cut_packagings_on_cut_item_and_kind", unique: true
    t.index ["cut_item_id"], name: "index_cut_packagings_on_cut_item_id"
  end

  create_table "cuts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", default: "Cut 1", null: false
    t.bigint "source_video_id", null: false
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["source_video_id"], name: "index_cuts_on_source_video_id"
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

  create_table "exports", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "cut_id", null: false
    t.text "error", default: "", null: false
    t.integer "item_count", default: 0, null: false
    t.string "package_rel_path", default: "", null: false
    t.boolean "skip_master", default: false, null: false
    t.bigint "source_video_id", null: false
    t.string "state", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.boolean "upscaled", default: false, null: false
    t.string "zip_rel_path", default: "", null: false
    t.index ["cut_id"], name: "index_exports_on_cut_id", unique: true
    t.index ["source_video_id"], name: "index_exports_on_source_video_id"
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

  create_table "pipeline_jobs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error", default: "", null: false
    t.integer "progress", default: 0, null: false
    t.bigint "source_video_id", null: false
    t.string "stage", default: "", null: false
    t.jsonb "stage_history", default: [], null: false
    t.string "status", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.jsonb "warnings", default: [], null: false
    t.index ["source_video_id"], name: "index_pipeline_jobs_on_source_video_id"
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

  create_table "source_videos", force: :cascade do |t|
    t.string "channel", default: "", null: false
    t.datetime "created_at", null: false
    t.integer "duration_s", default: 0, null: false
    t.bigint "project_id", null: false
    t.string "status", default: "queued", null: false
    t.string "title", default: "", null: false
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.string "youtube_id", null: false
    t.index ["project_id"], name: "index_source_videos_on_project_id"
    t.index ["youtube_id"], name: "index_source_videos_on_youtube_id", unique: true
  end

  create_table "topic_triages", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "source_video_id", null: false
    t.string "state", null: false
    t.bigint "topic_id", null: false
    t.datetime "updated_at", null: false
    t.index ["source_video_id", "topic_id"], name: "index_topic_triages_uniqueness", unique: true
    t.index ["source_video_id"], name: "index_topic_triages_on_source_video_id"
    t.index ["topic_id"], name: "index_topic_triages_on_topic_id"
  end

  create_table "topics", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.float "end_s", default: 0.0, null: false
    t.integer "ordinal", default: 0, null: false
    t.float "score", default: 0.0, null: false
    t.bigint "source_video_id", null: false
    t.float "start_s", default: 0.0, null: false
    t.text "summary", default: "", null: false
    t.string "title", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["source_video_id"], name: "index_topics_on_source_video_id"
  end

  create_table "transcripts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "language", default: "", null: false
    t.string "model", default: "", null: false
    t.jsonb "segments", default: [], null: false
    t.bigint "source_video_id", null: false
    t.datetime "updated_at", null: false
    t.index ["source_video_id"], name: "index_transcripts_on_source_video_id", unique: true
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

  add_foreign_key "audience_matches", "source_videos", on_delete: :cascade
  add_foreign_key "channel_snapshots", "competitor_channels", on_delete: :cascade
  add_foreign_key "chat_signals", "source_videos", on_delete: :cascade
  add_foreign_key "clips", "cut_items", on_delete: :cascade
  add_foreign_key "competitor_videos", "competitor_channels", on_delete: :cascade
  add_foreign_key "cut_items", "cuts", on_delete: :cascade
  add_foreign_key "cut_items", "topics", on_delete: :nullify
  add_foreign_key "cut_packagings", "cut_items", on_delete: :cascade
  add_foreign_key "cuts", "source_videos", on_delete: :cascade
  add_foreign_key "exports", "cuts", on_delete: :cascade
  add_foreign_key "own_channels", "projects", on_delete: :cascade
  add_foreign_key "packaging_changes", "competitor_videos", on_delete: :cascade
  add_foreign_key "pipeline_jobs", "source_videos", on_delete: :cascade
  add_foreign_key "project_channels", "competitor_channels", on_delete: :cascade
  add_foreign_key "project_channels", "projects", on_delete: :cascade
  add_foreign_key "source_videos", "projects", on_delete: :cascade
  add_foreign_key "topic_triages", "source_videos", on_delete: :cascade
  add_foreign_key "topic_triages", "topics", on_delete: :cascade
  add_foreign_key "topics", "source_videos", on_delete: :cascade
  add_foreign_key "transcripts", "source_videos", on_delete: :cascade
  add_foreign_key "video_attributes", "competitor_videos", on_delete: :cascade
  add_foreign_key "video_comments", "competitor_videos", on_delete: :cascade
  add_foreign_key "video_enrichments", "competitor_videos", on_delete: :cascade
  add_foreign_key "video_snapshots", "competitor_videos", on_delete: :cascade
end
