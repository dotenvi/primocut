module Metrics
  # The "channel spread" payload for one channel + format: the histogram of the
  # window's view counts plus the band thresholds, so a single render can mark any
  # video by its own view count. PURE READ. Ports the PoC
  # `service.py::channel_distribution` (+ `_distribution_payload`).
  #
  # It reads the SAME peer set as ChannelScores (via PeerWindow), so a channel's
  # spread and its classification never disagree. Two queries (videos + latest
  # views) — it never scans snapshots.
  class ChannelDistribution
    def initialize(channel, fmt:, config: Config.new, now: Time.current)
      @channel = channel
      @fmt = fmt
      @config = config
      @now = now
    end

    def call
      videos = @channel.competitor_videos.to_a
      views_by_id = PeerWindow.latest_views(videos.map(&:id))
      peers = PeerWindow.select(videos, views_by_id, is_short: @fmt == "short", now: @now, config: @config)
      peer_views = peers.map { |v| views_by_id[v.id] }

      ruler = Core.band_ruler(
        peer_views, basis: @config.band_basis, cutoffs: @config.band_cutoffs,
        min_sample: @config.outlier_min_sample
      )
      hist = Core.spread_histogram(peer_views)

      {
        channel_id: @channel.youtube_channel_id,
        format: @fmt,
        count: peer_views.length,
        basis: @config.band_basis,
        median: ruler&.median,
        thresholds: ruler&.thresholds,
        min: hist&.min,
        max: hist&.max,
        buckets: hist ? hist.counts : [],
        bucket_edges: hist ? hist.edges : []
      }
    end
  end
end
