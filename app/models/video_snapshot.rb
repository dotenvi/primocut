class VideoSnapshot < ApplicationRecord
  belongs_to :competitor_video

  validates :captured_at, presence: true
end
