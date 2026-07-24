class CompetitorChannel < ApplicationRecord
  has_many :project_channels, dependent: :delete_all
  has_many :projects, through: :project_channels
  has_many :competitor_videos, dependent: :delete_all
  has_many :channel_snapshots, dependent: :delete_all

  enum :backfill_state,
       { pending: "pending", queued: "queued", running: "running",
         done: "done", error: "error", skipped: "skipped" },
       prefix: :backfill

  validates :youtube_channel_id, presence: true, uniqueness: true

  # Hard delete means "nothing left". The DB cascades videos/snapshots/etc.;
  # events carry no FK (append-only log), so their cleanup is explicit here.
  # `prepend` so it runs BEFORE the dependent: :delete_all drops the videos —
  # otherwise their ids are gone before we can purge their events.
  before_destroy :purge_events, prepend: true

  private

  def purge_events
    video_ids = competitor_videos.pluck(:id)
    Event.where(competitor_channel_id: id).delete_all
    Event.where(competitor_video_id: video_ids).delete_all if video_ids.any?
  end
end
