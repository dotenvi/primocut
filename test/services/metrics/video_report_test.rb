require "test_helper"

# DB-backed tests for the per-video report payload. Covers the live computations
# (VPH from snapshot deltas, outlier verdict, engagement) and the read-through of
# the attribute/comment/packaging tables that stay empty until later phases.
class Metrics::VideoReportTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 7, 14, 12, 0, 0)

  setup do
    @channel = CompetitorChannel.create!(youtube_channel_id: "UC_vr", title: "VR")
    @seq = 0
    # A baseline of typical long-form peers so the target can be scored.
    10.times { peer(views: 1000) }
  end

  def peer(views:)
    @seq += 1
    v = @channel.competitor_videos.create!(
      youtube_video_id: "p#{@seq}", title: "P#{@seq}", published_at: NOW - (60 * 86_400)
    )
    v.video_snapshots.create!(captured_at: NOW - (60 * 86_400), views:)
    v
  end

  def report_for(video, now: NOW)
    Metrics::VideoReport.new(video, now:).call
  end

  test "reports metadata, snapshot series and live VPH from deltas" do
    video = @channel.competitor_videos.create!(
      youtube_video_id: "target", title: "The Target", is_short: false,
      published_at: NOW - (60 * 86_400), duration_s: 600, thumbnail_url: "http://x/t.jpg"
    )
    video.video_snapshots.create!(captured_at: NOW - (24 * 3600), views: 100, likes: 8, comments: 1)
    video.video_snapshots.create!(captured_at: NOW, views: 340, likes: 40, comments: 6)

    r = report_for(video)
    assert_equal "target", r[:video][:youtube_video_id]
    assert_equal "The Target", r[:video][:title]
    assert_equal 600, r[:video][:duration_s]
    assert_equal 2, r[:snapshots].length
    assert_equal 10.0, r[:vph][:current] # (340-100)/24h
    assert_equal [ 10.0 ], r[:vph][:series].map { |p| p[:vph] }
    # Engagement from the latest snapshot: 40/340 likes, 6/340 comments.
    assert_in_delta 40.0 / 340, r[:engagement][:like_rate], 1e-9
    assert_in_delta 6.0 / 340, r[:engagement][:comment_rate], 1e-9
  end

  test "classifies a viral against its channel baseline" do
    viral = @channel.competitor_videos.create!(
      youtube_video_id: "viral", title: "Viral", published_at: NOW - (60 * 86_400)
    )
    viral.video_snapshots.create!(captured_at: NOW, views: 1_000_000)

    r = report_for(viral)
    assert_equal "exceptional", r[:outlier][:band]
    assert_equal "long", r[:outlier][:format]
    assert_equal "ok", r[:outlier][:status]
  end

  test "reads attributes by source and leaves empty phases empty" do
    video = @channel.competitor_videos.create!(
      youtube_video_id: "attr", title: "HAS CAPS?!", published_at: NOW - (60 * 86_400)
    )
    video.video_snapshots.create!(captured_at: NOW, views: 1000)
    video.video_attributes.create!(
      source: Metrics::Attributes::SOURCE, state: "done",
      attrs: Metrics::Attributes.syntactic_attributes(video.title)
    )
    video.packaging_changes.create!(field: "title", old_value: "Old", new_value: "HAS CAPS?!", detected_at: NOW - (5 * 86_400))

    r = report_for(video)
    assert r[:attributes].key?("syntactic")
    assert_equal true, r[:attributes]["syntactic"][:values]["has_question"]
    assert_nil r[:comment_synthesis]          # nothing synthesised yet (Phase 3)
    assert_equal 0, r[:comments][:collected]  # nothing collected yet
    assert_equal 1, r[:packaging_changes].length
    assert_equal "title", r[:packaging_changes].first[:field]
  end

  test "a video with no snapshot degrades to insufficient sample, not a crash" do
    video = @channel.competitor_videos.create!(
      youtube_video_id: "empty", title: "Empty", published_at: NOW - (60 * 86_400)
    )

    r = report_for(video)
    assert_equal "insufficient_sample", r[:outlier][:status]
    assert_nil r[:vph][:current]
    assert_equal [], r[:snapshots]
    assert_nil r[:engagement][:like_rate]
  end
end
