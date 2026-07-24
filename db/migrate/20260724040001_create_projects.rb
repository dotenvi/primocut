class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.string :name, null: false
      t.text :description, null: false, default: ""
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :projects, :name, unique: true
  end
end
