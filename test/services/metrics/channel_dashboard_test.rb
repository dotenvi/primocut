require "test_helper"

# DB-backed tests for the channel dashboard payload: header stats, per-format
# baselines, the outlier ranking, engagement medians, cadence, packaging and
# resurgences. Mirrors service.py::channel_dashboard.
class Metrics::ChannelDashboardTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 7, 14, 12, 0, 0)

  setup do
    @channel = CompetitorChannel.create!(youtube_channel_id: "UC_cd", title: "Chan", handle: "@chan")
    @seq = 0
    10.times { peer(views: 1000, likes: 80, comments: 6) }
  end

  def peer(views:, likes: 0, comments: 0, is_short: false, age_days: 60)
    @seq += 1
    v = @channel.competitor_videos.create!(
      youtube_video_id: "c#{@seq}", title: "C#{@seq}", is_short:,
      published_at: NOW - (age_days * 86_400), duration_s: is_short ? 45 : 600
    )
    v.video_snapshots.create!(captured_at: NOW - (age_days * 86_400) + 3600, views:, likes:, comments:)
    v
  end

  def dashboard = Metrics::ChannelDashboard.new(@channel, now: NOW).call

  test "header stats come from the latest channel snapshot" do
    @channel.channel_snapshots.create!(captured_at: NOW - 3600, subscribers: 4000, total_views: 9_000_000, video_count: 120)
    @channel.channel_snapshots.create!(captured_at: NOW, subscribers: 5000, total_views: 10_000_000, video_count: 123)

    d = dashboard
    assert_equal "UC_cd", d[:channel][:channel_id]
    assert_equal "@chan", d[:channel][:handle]
    assert_equal 5000, d[:channel][:subscribers] # latest wins
    assert_equal 123, d[:channel][:video_count]
  end

  test "outliers are ranked most-viral first, per format" do
    peer(views: 500_000)   # a big outlier
    peer(views: 1_000_000) # an even bigger one

    d = dashboard
    long = d[:outliers]["long"]
    assert_equal [ 1_000_000, 500_000 ], long.first(2).map { |o| o[:views] }
    assert_equal "exceptional", long.first[:band]
    assert_equal [], d[:outliers]["short"]
  end

  test "baselines expose the per-format ruler" do
    d = dashboard
    assert_equal 1000.0, d[:baselines]["long"][:median]
    assert_equal "percentile", d[:baselines]["long"][:basis]
    assert_nil d[:baselines]["short"] # no Shorts → no ruler
  end

  test "engagement medians and cadence are per format" do
    d = dashboard
    # All 10 long peers have 80/1000 like rate and 6/1000 comment rate.
    assert_in_delta 0.08, d[:engagement]["long"][:like_rate_median], 1e-9
    assert_in_delta 0.006, d[:engagement]["long"][:comment_rate_median], 1e-9
    assert_operator d[:cadence][:uploads_per_week], :>, 0
    assert_equal 10, d[:cadence][:by_weekday].values.sum
    assert_equal 600, d[:cadence][:duration_by_format]["long"]["median_s"]
  end

  test "packaging log carries the before/after delta" do
    v = @channel.competitor_videos.first
    v.packaging_changes.create!(field: "title", old_value: "A", new_value: "B", detected_at: NOW - (10 * 86_400), vph_before: 4.0, vph_after: 25.0)

    row = dashboard[:packaging].find { |p| p[:video_id] == v.youtube_video_id }
    refute_nil row
    assert_equal 21.0, row[:delta]
  end

  test "an old video spiking after a dormant baseline is a resurgence" do
    v = @channel.competitor_videos.create!(
      youtube_video_id: "resurg", title: "Resurgent", published_at: NOW - (120 * 86_400)
    )
    views = 0
    8.downto(1) do |day|
      v.video_snapshots.create!(captured_at: NOW - (day * 86_400), views:)
      views += 240 # ~10/h baseline
    end
    v.video_snapshots.create!(captured_at: NOW, views: views + 2400) # last 24h: 100/h spike

    long = dashboard[:resurgences]["long"]
    assert_includes long.map { |r| r[:video_id] }, "resurg"
  end
end
