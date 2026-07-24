require "test_helper"

# Tests for the channel backfill service (YouTube fully faked, no network).
# Covers: new-channel collection with is_short/thumbnail_hash, the first
# channel+video snapshots the backfill writes itself, API-error degradation
# (never crashes), a channel-stats failure isolated from the uploads, and quota
# accounting. Ported from the PoC `tests/test_channel_backfill.py`.
class Competitors::BackfillTest < ActiveSupport::TestCase
  Api = Adapters::YoutubeApi
  NOW = Time.utc(2026, 7, 15, 12, 0, 0)

  # A fake YoutubeApi with in-memory quota accounting (1 unit per batch of 50).
  class FakeYouTube
    attr_reader :units_used

    def initialize(videos:, stats: :ok)
      @videos = videos
      @stats = stats
      @units_used = 0
    end

    def list_uploads_video_ids(_playlist_id, limit: 120)
      ids = @videos.map(&:video_id).first(limit)
      @units_used += (ids.size + 49) / 50
      ids
    end

    def list_videos(video_ids)
      by_id = @videos.index_by(&:video_id)
      @units_used += (video_ids.size + 49) / 50
      video_ids.map { |v| by_id.fetch(v) }
    end

    def get_channels_stats(channel_ids)
      raise Api::Error, "channels.list unavailable" if @stats == :boom

      @units_used += (channel_ids.size + 49) / 50
      channel_ids.map do |cid|
        Api::ChannelStats.new(channel_id: cid, subscribers: 1000, total_views: 50_000, video_count: 7)
      end
    end
  end

  # A client whose uploads listing fails outright (e.g. quota exceeded).
  class BoomYouTube < FakeYouTube
    def list_uploads_video_ids(*) = raise(Api::Error, "quota exceeded")
  end

  def videos(count = 120)
    # Alternate a Short (30s) and a long-form (600s) video.
    (0...count).map do |i|
      Api::VideoInfo.new(
        video_id: format("vid%03d", i), title: "V#{i}", published_at: nil,
        duration_s: i.even? ? 30 : 600, thumbnail_url: "https://i.ytimg.com/vi/vid#{i}/hq.jpg",
        view_count: 100 * i, like_count: 10 * i, comment_count: i
      )
    end
  end

  def channel(uploads: "UUchan", **attrs)
    CompetitorChannel.create!(youtube_channel_id: "UCchan0000000000000000", uploads_playlist_id: uploads, **attrs)
  end

  # Deterministic bytes → deterministic sha256, no network.
  def fake_thumb = ->(url) { url.b }

  def backfill(client, now: NOW)
    Competitors::Backfill.new(client:, thumbnail_fetcher: fake_thumb).call("UCchan0000000000000000", now:)
  end

  test "collects 120 videos with is_short and thumbnail hash" do
    channel(backfill_state: "queued")
    client = FakeYouTube.new(videos: videos(120))

    res = backfill(client)

    assert_equal 120, res[:videos]
    ch = CompetitorChannel.find_by(youtube_channel_id: "UCchan0000000000000000")
    assert ch.backfill_done?
    assert_equal 120, ch.backfill_done
    assert_equal 120, ch.backfill_total
    vids = ch.competitor_videos
    assert_equal 120, vids.count
    assert_equal 60, vids.where(is_short: true).count # every even index is 30s ≤ 180s
    assert vids.all? { |v| v.thumbnail_hash.present? }
  end

  test "flags shorts up to three minutes inclusive" do
    channel
    durations = [ 60, 63, 180, 181 ]
    vids = durations.map do |d|
      Api::VideoInfo.new(
        video_id: format("dur%03d", d), title: "V#{d}", published_at: nil, duration_s: d,
        thumbnail_url: "https://i.ytimg.com/vi/dur#{d}/hq.jpg", view_count: 1, like_count: 1, comment_count: 1
      )
    end
    backfill(FakeYouTube.new(videos: vids))

    by_id = CompetitorVideo.all.index_by(&:youtube_video_id)
    assert by_id["dur060"].is_short
    assert by_id["dur063"].is_short # was misclassified under the old 60s cap
    assert by_id["dur180"].is_short # the boundary is inclusive
    assert_not by_id["dur181"].is_short
  end

  test "quota accounting: 120 videos cost seven units" do
    channel
    client = FakeYouTube.new(videos: videos(120))
    res = backfill(client)
    # 3 playlist pages (3u) + 3 video batches (3u) + channel statistics (1u) = 7.
    assert_equal 7, res[:quota_units]
    assert_equal 7, client.units_used
  end

  test "writes the first video snapshots at one shared instant" do
    channel(backfill_state: "queued")
    backfill(FakeYouTube.new(videos: videos(4)))

    assert_equal 4, VideoSnapshot.count
    snap = CompetitorVideo.find_by(youtube_video_id: "vid002").video_snapshots.sole
    assert_equal [ 200, 20, 2 ], [ snap.views, snap.likes, snap.comments ]
    assert_equal NOW, snap.captured_at
  end

  test "writes the first channel snapshot" do
    channel(backfill_state: "queued")
    backfill(FakeYouTube.new(videos: videos(4)))

    snap = CompetitorChannel.find_by(youtube_channel_id: "UCchan0000000000000000").channel_snapshots.sole
    assert_equal [ 1000, 50_000, 7 ], [ snap.subscribers, snap.total_views, snap.video_count ]
    assert_equal NOW, snap.captured_at
  end

  test "all snapshots share one captured_at" do
    channel(backfill_state: "queued")
    backfill(FakeYouTube.new(videos: videos(4)), now: Time.current)

    stamps = VideoSnapshot.pluck(:captured_at) + ChannelSnapshot.pluck(:captured_at)
    assert_equal 1, stamps.uniq.size
  end

  test "channel-stats failure costs only the channel snapshot" do
    channel(backfill_state: "queued")
    res = backfill(FakeYouTube.new(videos: videos(4), stats: :boom))

    assert_equal 4, res[:videos]
    assert_nil res[:error]
    assert_equal 4, VideoSnapshot.count # uploads still written
    assert_equal 0, ChannelSnapshot.count # the degraded part
    ch = CompetitorChannel.find_by(youtube_channel_id: "UCchan0000000000000000")
    assert ch.backfill_done?
    assert_nil ch.backfill_error
  end

  test "api error degrades without crashing" do
    channel(backfill_state: "queued")
    res = backfill(BoomYouTube.new(videos: videos))

    assert_includes res[:error], "quota exceeded" # returned, not raised
    ch = CompetitorChannel.find_by(youtube_channel_id: "UCchan0000000000000000")
    assert ch.backfill_error?
    assert_includes ch.backfill_error, "quota exceeded"
  end

  test "raises when the channel is unknown" do
    assert_raises(ArgumentError) { backfill(FakeYouTube.new(videos: videos(1))) }
  end
end
