# An LLM-selected segment of a source video's transcript (the PoC `TopicRow`).
# Regenerating the source video's topics replaces the whole set. A topic item in
# a cut references a topic with `nullify`, so it degrades to a manual range
# instead of vanishing when the set is regenerated.
class Topic < ApplicationRecord
  belongs_to :source_video

  has_many :topic_triages, dependent: :destroy
  has_many :cut_items, dependent: :nullify

  validates :title, presence: true

  scope :ordered, -> { order(:ordinal) }
end
