require "test_helper"

# DB-backed tests for the niche (project) dashboard: cross-channel outlier ranking
# with per-video VPH, and the per-format conditional pattern wiring (outlier vs.
# control grouping by band and attribute source). Mirrors service.py::project_dashboard.
class Metrics::NicheDashboardTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 7, 14, 12, 0, 0)

  setup do
    @project = Project.create!(name: "Chess")
    @vseq = 0
  end

  def channel(slug)
    ch = CompetitorChannel.create!(youtube_channel_id: "UC_#{slug}", title: slug.to_s)
    @project.project_channels.create!(competitor_channel: ch)
    ch
  end

  def video(chan, title:, views:, is_short: false, series: nil)
    @vseq += 1
    v = chan.competitor_videos.create!(
      youtube_video_id: "v#{@vseq}", title:, is_short:, published_at: NOW - (60 * 86_400)
    )
    (series || [ [ NOW - (60 * 86_400) + 3600, views ] ]).each do |cap, val|
      v.video_snapshots.create!(captured_at: cap, views: val)
    end
    v
  end

  def dashboard = Metrics::NicheDashboard.new(@project, now: NOW).call

  test "ranks outliers across channels, most-viral first, tagged with channel and VPH" do
    a = channel(:a)
    b = channel(:b)
    10.times { video(a, title: "base", views: 1000) }
    10.times { video(b, title: "base", views: 1000) }
    video(a, title: "Big", views: 1_000_000, series: [ [ NOW - (24 * 3600), 900_000 ], [ NOW, 1_000_000 ] ])
    video(b, title: "Mid", views: 500_000)

    d = dashboard
    assert_equal({ id: @project.id, name: "Chess" }, d[:project])
    assert_equal 2, d[:channels].length
    assert_equal [], d[:audience_requests]

    long = d[:outliers]["long"]
    # The two virals lead by median multiple (1000× and 500×), regardless of channel.
    assert_equal [ 1_000_000, 500_000 ], long.first(2).map { |o| o[:views] }
    top = long.first
    assert_equal "exceptional", top[:band]
    assert_equal "UC_a", top[:channel_id]
    assert_operator top[:current_vph], :>, 0 # 100k over 24h
  end

  test "conditional patterns group outliers vs control by band and source" do
    c = channel(:solo)
    20.times { |i| video(c, title: "plain #{i}", views: 1000) }        # control, no '?'
    10.times { |i| video(c, title: "Question #{i}?", views: 100_000) } # banded outliers, with '?'
    c.competitor_videos.each do |v|
      v.video_attributes.create!(
        source: Metrics::Attributes::SOURCE, state: "done",
        attrs: Metrics::Attributes.syntactic_attributes(v.title)
      )
    end

    pattern = dashboard[:patterns]["long"].find { |p| p[:attribute] == "has_question" }
    refute_nil pattern
    assert_equal "positive", pattern[:verdict]
    assert_equal "syntactic", pattern[:source]
    assert_equal 10, pattern[:n_outlier]
    assert_equal 20, pattern[:n_control]
  end

  test "an empty project yields empty collections, not an error" do
    d = dashboard
    assert_equal [], d[:channels]
    assert_equal [], d[:outliers]["long"]
    assert_equal [], d[:patterns]["long"]
    assert_equal [], d[:resurgences]["short"]
  end
end
