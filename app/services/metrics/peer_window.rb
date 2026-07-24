module Metrics
  # The same-format rolling window that feeds BOTH the band ruler and the spread
  # histogram, plus the latest-view lookup it depends on. Kept in ONE place on
  # purpose (the PoC's single-definition rule): the ruler and the distribution read
  # the identical peer set, so a channel's classification and its spread can never
  # diverge.
  module PeerWindow
    module_function

    # Latest snapshot views per video id → { id => views }. DISTINCT ON is the
    # Postgres idiom for "one row per group"; it lives here (not behind a Repository,
    # §2.5) as a single visible query to tune if a dashboard ever proves slow. The
    # id tiebreak keeps the pick deterministic when two snapshots share captured_at.
    def latest_views(video_ids)
      return {} if video_ids.empty?

      VideoSnapshot
        .where(competitor_video_id: video_ids)
        .select("DISTINCT ON (competitor_video_id) competitor_video_id, views")
        .order("competitor_video_id, captured_at DESC, id DESC")
        .each_with_object({}) { |snap, acc| acc[snap.competitor_video_id] = snap.views }
    end

    # The peer set: the smaller of "the last N videos" and "the last D days",
    # same-format and scored (has a snapshot) only.
    def select(videos, views_by_id, is_short:, now:, config:)
      window_cut = now - (config.outlier_window_days * 86_400)
      peers = videos.select do |v|
        v.is_short == is_short && !v.published_at.nil? &&
          v.published_at >= window_cut && views_by_id.key?(v.id)
      end
      peers.sort_by { |v| [ v.published_at, v.id ] }.reverse.first(config.outlier_window_videos)
    end
  end
end
