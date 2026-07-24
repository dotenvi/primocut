module Metrics
  # Packaging-impact backfill: fill `packaging_changes.vph_before/vph_after`.
  #
  # This is the one derived figure the data model asks us to persist. It is
  # computed from the video's snapshot deltas (never totals, via
  # [[Metrics::Core]].packaging_impact) and written back only once the "after"
  # window has fully elapsed, so the operation is idempotent and safe to run
  # repeatedly (from the snapshot cycle or a manual metrics refresh). Ported from
  # the PoC `metrics/impact.py`.
  module Impact
    module_function

    # Fill vph_before/vph_after for changes whose window has elapsed and that are
    # still pending (vph_after NULL). Returns the number of changes filled.
    def backfill_packaging_impact(now: Time.current, config: Metrics::Config.new)
      window_days = config.packaging_impact_window_days
      filled = 0

      PackagingChange.where(vph_after: nil).find_each do |change|
        impact = Core.packaging_impact(
          snaps(change.competitor_video),
          detected_at: change.detected_at, now:, window_days:
        )
        next if impact.vph_after.nil? # window not elapsed yet — leave it pending

        change.update!(vph_before: impact.vph_before, vph_after: impact.vph_after)
        filled += 1
      end

      Rails.logger.info("packaging impact: filled #{filled} event(s)") if filled.positive?
      filled
    end

    def snaps(video)
      video.video_snapshots.order(:captured_at).map do |r|
        Core::Snap.new(captured_at: r.captured_at, views: r.views)
      end
    end
  end
end
