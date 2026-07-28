require "test_helper"

# Tests for the continuous-collection cycle (YouTube API + thumbnail download
# fully faked, no network). Covers frequency selection (all vs recent), snapshot
# recording, new-video detection, title change, thumbnail change under an
# UNCHANGED URL (byte hash), per-channel isolation, orphan exclusion, the
# cycle_done ops record and per-cycle quota accounting. Ported from the PoC
# `tests/test_snapshot_cycle.py`.
class Competitors::SnapshotCycleTest < ActiveSupport::TestCase
  Api = Adapters::YoutubeApi
  NOW = Time.utc(2026, 7, 14, 12, 0, 0)

  # A fake YoutubeApi with in-memory quota accounting.
  class FakeYouTube
    attr_accessor :channel_stats, :uploads, :videos, :fail_channels, :comments
    attr_reader :units_used, :comment_calls

    def initialize
      @channel_stats = {}   # channel_id -> ChannelStats
      @uploads = {}         # playlist_id -> top video ids
      @videos = {}          # video_id -> VideoInfo
      @comments = {}        # video_id -> [CommentInfo]
      @fail_channels = Set.new
      @comment_calls = []
      @units_used = 0
    end

    def list_top_comments(video_id, pages: 2)
      @comment_calls << [ video_id, pages ]
      @units_used += pages
      Array(@comments[video_id])
    end

    def get_channels_stats(ids)
      @units_used += 1
      ids.filter_map do |cid|
        raise Api::Error, "boom #{cid}" if @fail_channels.include?(cid)

        @channel_stats[cid]
      end
    end

    def list_uploads_video_ids(playlist_id, limit: 15)
      @units_used += 1
      (@uploads[playlist_id] || []).first(limit)
    end

    def list_videos(video_ids)
      @units_used += (video_ids.size + 49) / 50 if video_ids.any?
      video_ids.filter_map { |v| @videos[v] }
    end
  end

  # Thumbnail byte source keyed by URL (default: the URL's own bytes).
  class FakeThumbs
    attr_reader :content

    def initialize = @content = {}
    def call(url) = @content.fetch(url, url)
  end

  # Records what the cycle reported, so the phase trail can be asserted without
  # a terminal.
  class RecordingReporter
    attr_reader :updates, :warnings

    def initialize
      @updates = []
      @warnings = []
    end

    def update(stage:, progress:, detail: nil, **) = @updates << { stage:, progress:, detail: }
    def warn(message) = @warnings << message
    def close = nil

    def stages = @updates.map { |u| u[:stage] }.chunk_while { |a, b| a == b }.map(&:first)
    def details = @updates.filter_map { |u| u[:detail] }
  end

  def h(data) = Digest::SHA256.hexdigest(data)

  def vinfo(vid, title: "T", thumb: "", views: 100, likes: 10, comments: 1, published: nil)
    Api::VideoInfo.new(
      video_id: vid, title:, published_at: published, duration_s: 600,
      thumbnail_url: thumb, view_count: views, like_count: likes, comment_count: comments
    )
  end

  def seed_channel(cid = "UCc", active: true)
    CompetitorChannel.create!(youtube_channel_id: cid, uploads_playlist_id: "UU#{cid}", active:)
  end

  def seed_video(channel, vid, **attrs)
    channel.competitor_videos.create!(youtube_video_id: vid, **attrs)
  end

  def run_cycle(scope, yt, thumbs: FakeThumbs.new, now: NOW)
    Competitors::SnapshotCycle.new(client: yt, thumbnail_fetcher: thumbs).call(scope:, now:)
  end

  def snapshotted_ids = CompetitorVideo.joins(:video_snapshots).distinct.pluck(:youtube_video_id)

  # ------------------------- frequency selection -------------------------

  test "recent scope selects only young videos" do
    ch = seed_channel
    seed_video(ch, "vold", title: "old", published_at: NOW - 30.days)
    seed_video(ch, "vnew", title: "new", published_at: NOW - 2.days)
    yt = FakeYouTube.new
    yt.videos = { "vold" => vinfo("vold", title: "old"), "vnew" => vinfo("vnew", title: "new") }

    run_cycle("recent", yt)

    assert_equal [ "vnew" ], snapshotted_ids # < 7 days only
  end

  test "all scope selects every video" do
    ch = seed_channel
    seed_video(ch, "vold", title: "old", published_at: NOW - 30.days)
    seed_video(ch, "vnew", title: "new", published_at: NOW - 2.days)
    yt = FakeYouTube.new
    yt.videos = { "vold" => vinfo("vold", title: "old"), "vnew" => vinfo("vnew", title: "new") }

    run_cycle("all", yt)

    assert_equal %w[vnew vold], snapshotted_ids.sort
  end

  # ------------------------- snapshot recording -------------------------

  test "records channel and video snapshots at one shared instant" do
    ch = seed_channel
    seed_video(ch, "v1", title: "T", published_at: NOW - 1.day)
    yt = FakeYouTube.new
    yt.channel_stats = { "UCc" => Api::ChannelStats.new(channel_id: "UCc", subscribers: 1200, total_views: 99, video_count: 42) }
    yt.videos = { "v1" => vinfo("v1", views: 500, likes: 40, comments: 3) }

    run_cycle("all", yt)

    cs = ChannelSnapshot.sole
    assert_equal [ 1200, 42 ], [ cs.subscribers, cs.video_count ]
    vs = VideoSnapshot.sole
    assert_equal [ 500, 40, 3 ], [ vs.views, vs.likes, vs.comments ]
    assert_equal NOW, cs.captured_at
    assert_equal NOW, vs.captured_at
  end

  # ------------------------- new-video detection -------------------------

  test "new video detected, added and snapshotted" do
    ch = seed_channel
    seed_video(ch, "vknown", title: "known", published_at: NOW - 3.days)
    yt = FakeYouTube.new
    yt.uploads = { "UUUCc" => [ "vfresh", "vknown" ] } # vfresh is new at the top
    yt.videos = {
      "vknown" => vinfo("vknown"),
      "vfresh" => vinfo("vfresh", title: "fresh", published: NOW - 1.hour)
    }

    run_cycle("all", yt)

    assert CompetitorVideo.exists?(youtube_video_id: "vfresh") # added to competitor_videos
    assert_includes snapshotted_ids, "vfresh" # snapshotted
  end

  # ------------------------- packaging changes -------------------------

  test "title change recorded and stored title updated" do
    ch = seed_channel
    url = "https://i.ytimg.com/vi/v1/hq.jpg"
    # Seed a matching thumbnail hash so only the title differs.
    seed_video(ch, "v1", title: "Old title", thumbnail_url: url, thumbnail_hash: h(url), published_at: NOW - 1.day)
    yt = FakeYouTube.new
    yt.videos = { "v1" => vinfo("v1", title: "New title", thumb: url) }

    res = run_cycle("all", yt)

    change = PackagingChange.sole
    assert change.field_title?
    assert_equal [ "Old title", "New title" ], [ change.old_value, change.new_value ]
    assert_equal "New title", CompetitorVideo.find_by(youtube_video_id: "v1").title
    assert_equal 1, res[:packaging_changes]
    assert_equal 1, Event.where(event_type: "packaging_changed").count
  end

  test "thumbnail change detected with an unchanged url" do
    ch = seed_channel
    url = "https://i.ytimg.com/vi/v1/hq.jpg" # stays the same across the change
    seed_video(ch, "v1", title: "T", thumbnail_url: url, thumbnail_hash: h("old-bytes"), published_at: NOW - 1.day)
    thumbs = FakeThumbs.new
    thumbs.content[url] = "new-bytes" # same URL, different image bytes
    yt = FakeYouTube.new
    yt.videos = { "v1" => vinfo("v1", title: "T", thumb: url) }

    run_cycle("all", yt, thumbs:)

    change = PackagingChange.sole
    assert change.field_thumbnail?
    assert_equal h("old-bytes"), change.old_value
    assert_equal h("new-bytes"), change.new_value
    v = CompetitorVideo.find_by(youtube_video_id: "v1")
    assert_equal url, v.thumbnail_url            # URL unchanged
    assert_equal h("new-bytes"), v.thumbnail_hash # hash updated
  end

  # ------------------------- isolation / orphans / quota -------------------------

  test "per channel isolation" do
    bad = seed_channel("UCbad")
    ok = seed_channel("UCok")
    seed_video(bad, "vbad", published_at: NOW - 1.day)
    seed_video(ok, "vok", published_at: NOW - 1.day)
    yt = FakeYouTube.new
    yt.fail_channels = Set.new([ "UCbad" ]) # its channel-stats call raises
    yt.videos = { "vbad" => vinfo("vbad"), "vok" => vinfo("vok") }

    res = run_cycle("all", yt)

    assert_equal [ "vok" ], snapshotted_ids # the good channel still collected
    assert_equal 1, res[:channels]          # only UCok completed; UCbad was isolated
  end

  test "orphan channel excluded" do
    ch = seed_channel("UCorph", active: false) # deactivated → out of the cycle
    seed_video(ch, "v1", published_at: NOW - 1.day)
    yt = FakeYouTube.new
    yt.videos = { "v1" => vinfo("v1") }

    res = run_cycle("all", yt)

    assert_equal 0, res[:channels]
    assert_equal 0, VideoSnapshot.count
  end

  test "per cycle quota accounting" do
    ch = seed_channel
    seed_video(ch, "v1", published_at: NOW - 1.day)
    yt = FakeYouTube.new
    yt.channel_stats = { "UCc" => Api::ChannelStats.new(channel_id: "UCc", subscribers: 1, total_views: 1, video_count: 1) }
    yt.uploads = { "UUUCc" => [ "v1" ] }
    yt.videos = { "v1" => vinfo("v1") }

    res = run_cycle("all", yt)

    # 1 (channel stats) + 1 (uploads scan) + 1 (videos.list batch) = 3 units.
    assert_equal 3, res[:quota_units]
    assert_equal 3, yt.units_used
  end

  test "records a born-resolved cycle_done ops event" do
    ch = seed_channel
    seed_video(ch, "v1", published_at: NOW - 1.day)
    yt = FakeYouTube.new
    yt.videos = { "v1" => vinfo("v1") }

    run_cycle("all", yt)

    ev = Event.find_by(category: "ops", event_type: "cycle_done")
    assert_not_nil ev
    assert_equal NOW, ev.resolved_at # born resolved → never an open alert
    assert_equal "all", ev.payload["scope"]
    assert_equal 1, ev.payload["videos"]
  end

  test "a real cycle emits outlier_crossed through the pipeline" do
    ch = seed_channel
    # 12 long-format peers at the median baseline (relevant >= 3000 under fixed_multiple).
    12.times do |i|
      peer = seed_video(ch, "p#{i}", title: "Peer #{i}", published_at: NOW - (40 + i).days, duration_s: 600, is_short: false)
      peer.video_snapshots.create!(captured_at: NOW - 1.day, views: 1000, likes: 1, comments: 1)
    end
    yt = FakeYouTube.new
    yt.uploads = { "UUUCc" => [ "v1" ] } # a fresh target at the top of the uploads
    yt.videos = { "v1" => vinfo("v1", title: "Target", views: 3000, published: NOW - 30.days) }

    Competitors::SnapshotCycle.new(
      client: yt, thumbnail_fetcher: FakeThumbs.new, metrics_config: Metrics::Config.new(band_basis: "fixed_multiple")
    ).call(scope: "all", now: NOW)

    ev = Event.find_by(event_type: "outlier_crossed")
    assert_not_nil ev
    assert_equal "relevant", ev.payload["band"]
    assert_equal "v1", CompetitorVideo.find(ev.competitor_video_id).youtube_video_id
  end

  test "a real cycle collects the comments of an outlier it just detected" do
    ch = seed_channel
    12.times do |i|
      peer = seed_video(ch, "p#{i}", title: "Peer #{i}", published_at: NOW - (40 + i).days, duration_s: 600, is_short: false)
      peer.video_snapshots.create!(captured_at: NOW - 1.day, views: 1000, likes: 1, comments: 1)
    end
    yt = FakeYouTube.new
    yt.uploads = { "UUUCc" => [ "v1" ] }
    yt.videos = { "v1" => vinfo("v1", title: "Target", views: 3000, published: NOW - 30.days) }
    yt.comments = { "v1" => [ Api::CommentInfo.new(comment_id: "c0", text: "top", like_count: 9, author: "u0") ] }

    res = Competitors::SnapshotCycle.new(
      client: yt, thumbnail_fetcher: FakeThumbs.new, metrics_config: Metrics::Config.new(band_basis: "fixed_multiple")
    ).call(scope: "all", now: NOW)

    assert_equal 1, res[:comments]
    assert_equal [ "v1", 2 ], yt.comment_calls.sole # the crossing drove exactly one fetch
    v = CompetitorVideo.find_by(youtube_video_id: "v1")
    assert_equal "done", v.comments_state
    assert_equal 1, v.video_comments.count
  end

  test "rejects an unknown scope" do
    assert_raises(ArgumentError) { run_cycle("weekly", FakeYouTube.new) }
  end

  # ------------------------- progress reporting -------------------------

  test "reports every phase in order, ending at 100" do
    ch = seed_channel
    seed_video(ch, "v1", title: "One", published_at: NOW - 2.days)
    yt = FakeYouTube.new
    yt.videos = { "v1" => vinfo("v1", title: "One") }
    reporter = RecordingReporter.new

    Competitors::SnapshotCycle.new(client: yt, thumbnail_fetcher: FakeThumbs.new, reporter:).call(scope: "all", now: NOW)

    assert_equal [ "Channels", "Metrics artifacts", "Outlier events", "Comments", "Done" ], reporter.stages
    assert_equal 100, reporter.updates.last[:progress]
  end

  test "progress never goes backwards" do
    yt = FakeYouTube.new
    3.times do |i|
      ch = seed_channel("UC#{i}")
      seed_video(ch, "v#{i}", title: "V#{i}", published_at: NOW - 2.days)
      yt.videos["v#{i}"] = vinfo("v#{i}", title: "V#{i}")
    end
    reporter = RecordingReporter.new

    Competitors::SnapshotCycle.new(client: yt, thumbnail_fetcher: FakeThumbs.new, reporter:).call(scope: "all", now: NOW)

    progresses = reporter.updates.map { |u| u[:progress] }
    assert_equal progresses.sort, progresses
    assert_operator progresses.max, :<=, 100
  end

  test "the channel phase names the sub-step it is on, including per-thumbnail work" do
    ch = seed_channel
    seed_video(ch, "v1", title: "One", published_at: NOW - 2.days)
    seed_video(ch, "v2", title: "Two", published_at: NOW - 2.days)
    yt = FakeYouTube.new
    yt.videos = { "v1" => vinfo("v1", title: "One"), "v2" => vinfo("v2", title: "Two") }
    reporter = RecordingReporter.new

    Competitors::SnapshotCycle.new(client: yt, thumbnail_fetcher: FakeThumbs.new, reporter:).call(scope: "all", now: NOW)

    details = reporter.details.join("\n")
    assert_match(/1\/1 .*stats/, details)
    assert_match(/thumbs 2\/2/, details) # the slowest stretch counts item by item
    assert_match(/saving/, details)
    assert_match(/quota/, details) # spend is visible as it accrues, not only at the end
  end

  test "a channel failure is warned to the operator, not only to the log" do
    seed_channel("UCok")
    seed_channel("UCbad")
    yt = FakeYouTube.new
    yt.fail_channels << "UCbad"
    reporter = RecordingReporter.new

    result = Competitors::SnapshotCycle.new(
      client: yt, thumbnail_fetcher: FakeThumbs.new, reporter:
    ).call(scope: "all", now: NOW)

    assert_equal 1, result[:channels] # the good channel still completed
    assert_equal 1, reporter.warnings.size
    assert_match(/UCbad/, reporter.warnings.sole)
  end
end
