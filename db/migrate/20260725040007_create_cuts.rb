class CreateCuts < ActiveRecord::Migration[8.1]
  def change
    create_table :cuts do |t|
      # An ordered composition over one source video. A source video has N cuts;
      # each gets a default "Cut 1" created lazily. `status` leaves room for the
      # render step (`rendering`/`rendered`) but stays `draft` in the bench.
      t.references :source_video, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false, default: "Cut 1"
      t.string :status, null: false, default: "draft"

      t.timestamps
    end
  end
end
