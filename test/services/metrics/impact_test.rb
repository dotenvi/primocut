require "test_helper"

# Tests for the packaging-impact backfill (the one persisted derived figure).
# Ported from the PoC `tests/test_metrics_impact.py`.
class Metrics::ImpactTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 7, 14, 12, 0, 0)

  def seed(detected_at:, snaps:)
    ch = CompetitorChannel.create!(youtube_channel_id: "UCc0000000000000000000")
    v = ch.competitor_videos.create!(youtube_video_id: "v1", title: "t")
    snaps.each { |captured_at, views| v.video_snapshots.create!(captured_at:, views:, likes: 0, comments: 0) }
    v.packaging_changes.create!(field: "title", old_value: "a", new_value: "b", detected_at:)
    v
  end

  test "fills before and after once the window has elapsed" do
    detected = NOW - 8.days # the 7-day after-window has fully elapsed
    v = seed(detected_at: detected, snaps: [
      [ detected - 7.days, 0 ],
      [ detected, 700 ],          # before ≈ 4.17 views/h
      [ detected + 7.days, 4900 ] # after = 4200/7d = 25 views/h
    ])

    assert_equal 1, Metrics::Impact.backfill_packaging_impact(now: NOW)
    change = v.packaging_changes.sole
    assert_not_nil change.vph_before
    assert_not_nil change.vph_after
    assert change.vph_after > change.vph_before

    # Idempotent: a second run fills nothing more.
    assert_equal 0, Metrics::Impact.backfill_packaging_impact(now: NOW)
  end

  test "leaves pending until the window elapses" do
    detected = NOW - 2.days # only 2 of 7 days elapsed
    v = seed(detected_at: detected, snaps: [ [ detected - 7.days, 0 ], [ detected, 700 ], [ NOW, 900 ] ])

    assert_equal 0, Metrics::Impact.backfill_packaging_impact(now: NOW)
    assert_nil v.packaging_changes.sole.vph_after
  end
end
