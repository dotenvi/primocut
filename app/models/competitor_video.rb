class CompetitorVideo < ApplicationRecord
  belongs_to :competitor_channel

  has_many :video_snapshots, dependent: :delete_all
  has_many :packaging_changes, dependent: :delete_all
  has_many :video_attributes, dependent: :delete_all
  has_many :video_comments, dependent: :delete_all
  has_many :video_enrichments, dependent: :delete_all

  # `comments_state` and `last_band_emitted` keep "" as their initial state, so
  # they stay plain strings rather than enums.
  validates :youtube_video_id, presence: true, uniqueness: true
end
