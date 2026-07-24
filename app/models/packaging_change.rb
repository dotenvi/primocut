class PackagingChange < ApplicationRecord
  belongs_to :competitor_video

  enum :field, { title: "title", thumbnail: "thumbnail" }, prefix: :field

  validates :detected_at, presence: true
end
