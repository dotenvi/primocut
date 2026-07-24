require "test_helper"

# DB-backed tests for the channel spread payload. Mirrors the PoC
# service.py::channel_distribution: a SPREAD_BUCKETS histogram over the window's
# view counts plus the band thresholds, reading the same peer set as the scorer.
class Metrics::ChannelDistributionTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 7, 14, 12, 0, 0)

  setup do
    @channel = CompetitorChannel.create!(youtube_channel_id: "UC_dist", title: "Dist")
    @seq = 0
  end

  def add_video(views:, is_short: false)
    @seq += 1
    video = @channel.competitor_videos.create!(
      youtube_video_id: "d#{@seq}", title: "V#{@seq}",
      is_short:, published_at: NOW - (30 * 86_400)
    )
    video.video_snapshots.create!(captured_at: NOW - (30 * 86_400) + 3600, views:)
    video
  end

  def distribution(fmt)
    Metrics::ChannelDistribution.new(@channel, fmt:, now: NOW).call
  end

  test "spread histogram puts a lone viral in the tail" do
    20.times { add_video(views: 1000) }
    add_video(views: 100_000)

    dist = distribution("long")
    assert_equal 21, dist[:count]
    assert_equal Metrics::Core::SPREAD_BUCKETS, dist[:buckets].length
    assert_equal 20, dist[:buckets].first  # the cluster
    assert_equal 1, dist[:buckets].last    # the viral, alone in the last bar
    assert_equal 1000.0, dist[:median]
    assert_equal 100_000.0, dist[:max]
  end

  test "thresholds come from the band ruler over the same peer set" do
    (1..100).each { |v| add_video(views: v) }

    # Widen the window past the default 50 so all 100 peers count and the cutoffs
    # match the pure-core case exactly (nearest-rank 90/97/99 over 1..100).
    config = Metrics::Config.new(outlier_window_videos: 100)
    dist = Metrics::ChannelDistribution.new(@channel, fmt: "long", config:, now: NOW).call
    assert_equal({ "relevant" => 90.0, "strong" => 97.0, "exceptional" => 99.0 }, dist[:thresholds])
    assert_equal "percentile", dist[:basis]
  end

  test "an empty format yields a null-ish payload, not an error" do
    10.times { add_video(views: 1000, is_short: false) }

    dist = distribution("short") # no Shorts at all
    assert_equal 0, dist[:count]
    assert_nil dist[:median]
    assert_nil dist[:thresholds]
    assert_equal [], dist[:buckets]
  end

  test "below min_sample there is no ruler but the histogram still renders" do
    5.times { add_video(views: 1000) } # fewer than min_sample 10

    dist = distribution("long")
    assert_equal 5, dist[:count]
    assert_nil dist[:median]        # no ruler
    assert_nil dist[:thresholds]
    assert_equal Metrics::Core::SPREAD_BUCKETS, dist[:buckets].length # histogram is independent
  end
end
