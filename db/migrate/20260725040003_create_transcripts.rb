class CreateTranscripts < ActiveRecord::Migration[8.1]
  def change
    create_table :transcripts do |t|
      # One transcript per source video (the pay-once cache: a re-run whose
      # transcript already exists skips the download + GPU stages).
      t.references :source_video, null: false,
                   foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :language, null: false, default: ""
      t.string :model, null: false, default: ""
      t.jsonb :segments, null: false, default: []

      t.timestamps
    end
  end
end
