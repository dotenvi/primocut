class CreateOwnChannels < ActiveRecord::Migration[8.1]
  def change
    create_table :own_channels do |t|
      t.references :project, null: false,
                   foreign_key: { on_delete: :cascade }
      t.string :channel_url, null: false
      t.string :handle, null: false, default: ""
      t.string :title, null: false, default: ""
      t.string :role # 'main' | 'shorts' | free

      t.timestamps
    end

    add_index :own_channels, [ :project_id, :channel_url ], unique: true
  end
end
