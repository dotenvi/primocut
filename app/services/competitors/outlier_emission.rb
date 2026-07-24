module Competitors
  # Emit the `outlier_crossed` niche events the Radar feed reads, from the snapshot
  # cycle. An outlier score is computed on read and does not survive a recompute, so
  # the moment a video crosses into a band has to be recorded as a fact or it is
  # lost. But a video oscillating around a cut would record that fact every snapshot,
  # so emission fires ONLY on a transition to a strictly higher band than the one
  # last emitted (persisted in `competitor_videos.last_band_emitted`):
  #
  # - a video crossing relevant → strong → exceptional emits three events, one per
  #   rung of the ladder;
  # - a video flickering across the relevant cut emits exactly one.
  #
  # A provisional (younger than `outlier_provisional_days`) crossing carries
  # `provisional=true` in the payload; because the guard tracks the highest band
  # emitted, a provisional band that later matures at the same band does NOT
  # re-emit — only a genuine step up does. Comment collection (a later slice)
  # consumes these events as the single crossing-detection point.
  #
  # Isolation: a channel that fails to score is logged and skipped; a metrics/emit
  # error never costs the cycle its snapshots. Ported from the PoC
  # `worker/event_emission.py`.
  class OutlierEmission
    # "" (never emitted) ranks below every band, so the first crossing always fires.
    ORDINAL = { "" => -1 }.merge(Metrics::Core::BAND_NAMES.each_with_index.to_h).freeze

    def initialize(config: Metrics::Config.new, now: Time.current)
      @config = config
      @now = now
    end

    # Emit `outlier_crossed` for every video of the given channels that stepped up a
    # band since its last emission. Returns how many events were emitted.
    def call(channels)
      emitted = 0
      channels.each do |channel|
        emitted += emit_channel(channel)
      rescue StandardError => e # per-channel isolation: log and keep going
        Rails.logger.error("outlier emission: channel #{channel.youtube_channel_id} failed: #{e.message}")
        next
      end
      emitted
    end

    private

    def emit_channel(channel)
      scored = Metrics::ChannelScores.new(channel, config: @config, now: @now).call.scored
      videos = channel.competitor_videos.index_by(&:id)
      emitted = 0

      scored.each_value do |sc|
        band = sc.score.band
        next if band.nil?

        video = videos[sc.competitor_video_id]
        next if video.nil? || ordinal(band) <= ordinal(video.last_band_emitted)

        Event.create!(
          category: "niche", event_type: "outlier_crossed", severity: "info",
          competitor_channel_id: channel.id, competitor_video_id: video.id, occurred_at: @now,
          payload: {
            "band" => band, "median_multiple" => sc.score.median_multiple, "views" => sc.views,
            "baseline" => sc.score.baseline, "provisional" => sc.score.provisional,
            # Format travels so the Radar can pull the right channel-format spread
            # strip without first fetching the video.
            "is_short" => sc.is_short
          }
        )
        video.update!(last_band_emitted: band)
        emitted += 1
      end

      emitted
    end

    def ordinal(band) = ORDINAL.fetch(band || "", -1)
  end
end
