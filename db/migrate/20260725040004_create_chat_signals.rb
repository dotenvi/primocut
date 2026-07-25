class CreateChatSignals < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_signals do |t|
      # One chat signal per source video (optional — absent when the video has no
      # usable chat replay). Cached pay-once, like the transcript.
      t.references :source_video, null: false,
                   foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.jsonb :per_minute, null: false, default: []
      t.jsonb :peaks, null: false, default: []

      t.timestamps
    end
  end
end
