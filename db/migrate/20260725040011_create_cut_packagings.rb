class CreateCutPackagings < ActiveRecord::Migration[8.1]
  def change
    create_table :cut_packagings do |t|
      # An opt-in AI packaging artifact for ONE cut item: a clip is a video of its
      # own, so its titles / thumbnail brief / frame ranking are generated and
      # cached per clip. Cascades with the item. Paid for once by `content_hash`.
      t.references :cut_item, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :cut_id, null: false # denormalized so the export/bench can group
      t.string :kind, null: false   # "title" | "thumb_brief" | "frame_ranking"
      t.jsonb :payload, null: false, default: {}
      t.string :content_hash, null: false, default: ""
      t.string :state, null: false, default: "done" # "running" | "done" | "error"
      t.text :error, null: false, default: ""

      t.timestamps
    end
    add_index :cut_packagings, %i[cut_item_id kind], unique: true,
              name: "index_cut_packagings_on_cut_item_and_kind"
    add_index :cut_packagings, :cut_id
  end
end
