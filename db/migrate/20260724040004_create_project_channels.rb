class CreateProjectChannels < ActiveRecord::Migration[8.1]
  def change
    create_table :project_channels do |t|
      t.references :project, null: false,
                   foreign_key: { on_delete: :cascade }
      t.references :competitor_channel, null: false,
                   foreign_key: { on_delete: :cascade }

      t.timestamps
    end

    add_index :project_channels, [ :project_id, :competitor_channel_id ],
              unique: true, name: "index_project_channels_uniqueness"
  end
end
