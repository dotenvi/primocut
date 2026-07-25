# An ordered composition over one source video (the PoC `CutRow`). A source video
# has N cuts; each gets a default "Cut 1" lazily. Membership of a topic in the cut
# is derived exclusively from its ordered `cut_items`.
class Cut < ApplicationRecord
  belongs_to :source_video

  has_many :cut_items, -> { order(:position) }, dependent: :destroy
  has_one :export, dependent: :destroy

  enum :status,
       { draft: "draft", rendering: "rendering", rendered: "rendered" },
       prefix: :status, default: "draft"

  validates :name, presence: true
end
