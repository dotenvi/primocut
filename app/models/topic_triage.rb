# The user's per-source-video opinion about a topic (the PoC `TopicTriageRow`),
# persisted across sessions and shared across the source video's cuts. Only
# "maybe"/"discarded" are stored; the absence of a row means "open", and
# membership ("in") is derived from a cut's items, never written here.
class TopicTriage < ApplicationRecord
  belongs_to :source_video
  belongs_to :topic

  enum :state,
       { maybe: "maybe", discarded: "discarded" },
       prefix: :state

  validates :topic_id, uniqueness: { scope: :source_video_id }
end
