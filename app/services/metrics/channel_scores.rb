module Metrics
  # Classify every video of a competitor channel against its per-format band ruler,
  # computed live over the latest snapshot views. PURE READ — nothing is written.
  # Ports the PoC `service.py::_channel_scores` (+ `_window_peers`).
  #
  # SRP: one domain operation — score a channel. DIP: the clock (`now`) and the
  # settings (`config`) arrive through the constructor with real defaults, so
  # production reads clean and tests inject a fixed clock. Per-channel metrics depend
  # only on the channel's own data, so a channel shared by two projects yields
  # identical figures — the project only scopes which channels get ranked.
  class ChannelScores
    # Shorts and long-form are different products (monetisation, audience, format),
    # so every population is split by format — a figure blended across both describes
    # neither. Fixed order keeps a payload stable.
    FORMATS = [ [ "long", false ], [ "short", true ] ].freeze

    Scored = Data.define(:competitor_video_id, :youtube_video_id, :title, :is_short, :views, :score)

    # scored: { competitor_video_id => Scored }; rulers: { "long"|"short" => BandRuler|nil }
    Result = Data.define(:scored, :rulers)

    def initialize(channel, config: Config.new, now: Time.current)
      @channel = channel
      @config = config
      @now = now
    end

    def call
      videos = @channel.competitor_videos.to_a
      views_by_id = latest_views(videos.map(&:id))
      cutoffs = @config.band_cutoffs
      provisional_cut = @now - (@config.outlier_provisional_days * 86_400)

      rulers = FORMATS.to_h do |fmt, is_short|
        peers = window_peers(videos, views_by_id, is_short:)
        peer_views = peers.map { |v| views_by_id[v.id] }
        ruler = Core.band_ruler(peer_views, basis: @config.band_basis, cutoffs:, min_sample: @config.outlier_min_sample)
        [ fmt, ruler ]
      end

      scored = {}
      videos.each do |video|
        next unless views_by_id.key?(video.id) # no snapshot yet — cannot be scored

        provisional = video.published_at.nil? || video.published_at > provisional_cut
        score = Core.outlier_score(views_by_id[video.id], rulers[format_of(video)], provisional:)
        scored[video.id] = Scored.new(
          competitor_video_id: video.id, youtube_video_id: video.youtube_video_id,
          title: video.title, is_short: video.is_short, views: views_by_id[video.id], score:
        )
      end

      Result.new(scored:, rulers:)
    end

    private

    def format_of(video) = video.is_short ? "short" : "long"

    # The same-format rolling window that feeds the band ruler: the smaller of "the
    # last N videos" and "the last D days", scored videos only. This is the SINGLE
    # definition of the peer set — the ruler and the spread histogram both read it,
    # so a channel's classification and its distribution never diverge.
    def window_peers(videos, views_by_id, is_short:)
      window_cut = @now - (@config.outlier_window_days * 86_400)
      peers = videos.select do |v|
        v.is_short == is_short && !v.published_at.nil? &&
          v.published_at >= window_cut && views_by_id.key?(v.id)
      end
      peers.sort_by { |v| [ v.published_at, v.id ] }.reverse.first(@config.outlier_window_videos)
    end

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
  end
end
