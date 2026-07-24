class VideoAttribute < ApplicationRecord
  belongs_to :competitor_video

  enum :source,
       { syntactic: "syntactic", title_llm: "title_llm", thumbnail_llm: "thumbnail_llm" },
       prefix: :source
  enum :state,
       { running: "running", done: "done", error: "error" },
       prefix: :state

  validates :source, presence: true, uniqueness: { scope: :competitor_video_id }
end
