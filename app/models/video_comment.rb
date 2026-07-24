class VideoComment < ApplicationRecord
  belongs_to :competitor_video

  validates :comment_id, presence: true,
            uniqueness: { scope: :competitor_video_id }
end
