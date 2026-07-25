class CreateAudienceMatches < ActiveRecord::Migration[8.1]
  def change
    create_table :audience_matches do |t|
      # The cached audience -> topic match for a source video (opt-in, one cheap
      # LLM). One row per source video: the semantic match of the niche's
      # synthesised audience requests to the source video's topics. `payload` maps
      # topic_id -> the requests it delivers; `content_hash` folds the topics AND
      # the niche's request set, so it recomputes only when either changes. The
      # PoC `live_audience_match` — renamed off "live" to the source-video vocab.
      t.references :source_video, null: false, foreign_key: { on_delete: :cascade },
                   index: { unique: true }
      t.string :content_hash, null: false, default: ""
      t.jsonb :payload, null: false, default: {}
      t.string :state, null: false, default: "done"
      t.text :error, null: false, default: ""

      t.timestamps
    end
  end
end
