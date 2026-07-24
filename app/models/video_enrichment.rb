class VideoEnrichment < ApplicationRecord
  belongs_to :competitor_video

  enum :state,
       { running: "running", done: "done", error: "error" },
       prefix: :state

  # `kind` is an open taxonomy (only "comment_synthesis" today) — plain string.
  validates :kind, presence: true, uniqueness: { scope: :competitor_video_id }
end
