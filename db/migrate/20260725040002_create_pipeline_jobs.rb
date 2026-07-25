class CreatePipelineJobs < ActiveRecord::Migration[8.1]
  def change
    create_table :pipeline_jobs do |t|
      t.references :source_video, null: false, foreign_key: { on_delete: :cascade }
      t.string :stage, null: false, default: ""
      t.integer :progress, null: false, default: 0
      t.string :status, null: false, default: "queued" # queued | started | finished | failed
      t.jsonb :warnings, null: false, default: []
      t.jsonb :stage_history, null: false, default: []
      t.text :error, null: false, default: ""

      t.timestamps
    end
  end
end
