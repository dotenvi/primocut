require "test_helper"

# Tests for the anti-flapping `outlier_crossed` emission. The band basis is
# `fixed_multiple` so a target's band is a clean function of its view count against
# a median-1000 peer set: relevant >= 3000, strong >= 6000, exceptional >= 10000.
# Ported from the anti-flapping cases of the PoC `tests/test_events.py`.
class Competitors::OutlierEmissionTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 7, 14, 12, 0, 0)
  CONFIG = Metrics::Config.new(band_basis: "fixed_multiple")

  # A channel whose peers sit at the median baseline, plus a long-form target.
  def seed_channel_with_peers(peer_views: 1000, n_peers: 12)
    ch = CompetitorChannel.create!(youtube_channel_id: "UCc", uploads_playlist_id: "UUUCc")
    n_peers.times do |i|
      peer = ch.competitor_videos.create!(
        youtube_video_id: "p#{i}", title: "Peer #{i}", published_at: NOW - (40 + i).days, duration_s: 600, is_short: false
      )
      peer.video_snapshots.create!(captured_at: NOW - 1.day, views: peer_views, likes: 1, comments: 1)
    end
    ch
  end

  def target(channel, published: NOW - 30.days)
    channel.competitor_videos.create!(youtube_video_id: "v1", title: "Target", published_at: published, duration_s: 600, is_short: false)
  end

  def set_views(video, views, at:)
    video.video_snapshots.create!(captured_at: at, views:, likes: 1, comments: 1)
  end

  def emit(channel, now:)
    Competitors::OutlierEmission.new(config: CONFIG, now:).call([ channel ])
  end

  def crossings(video)
    Event.where(event_type: "outlier_crossed", competitor_video_id: video.id).order(:id)
  end

  test "a video oscillating around the cut emits exactly one event" do
    ch = seed_channel_with_peers
    v = target(ch)

    # crosses (relevant) → drops below → crosses again, each its own cycle.
    [ 3000, 2000, 3500, 2500, 3200 ].each_with_index do |views, i|
      set_views(v, views, at: NOW + i.hours)
      emit(ch, now: NOW + i.hours)
    end

    assert_equal 1, crossings(v).count
    assert_equal "relevant", crossings(v).first.payload["band"]
  end

  test "climbing the band ladder emits one event per rung" do
    ch = seed_channel_with_peers
    v = target(ch)

    [ 3000, 6000, 10_000 ].each_with_index do |views, i|
      set_views(v, views, at: NOW + i.hours)
      emit(ch, now: NOW + i.hours)
    end

    assert_equal %w[relevant strong exceptional], crossings(v).map { |e| e.payload["band"] }
  end

  test "a step up after a drop still emits" do
    ch = seed_channel_with_peers
    v = target(ch)

    [ 3000, 1000, 6000 ].each_with_index do |views, i| # relevant, none, strong
      set_views(v, views, at: NOW + i.hours)
      emit(ch, now: NOW + i.hours)
    end

    assert_equal %w[relevant strong], crossings(v).map { |e| e.payload["band"] }
  end

  test "a provisional crossing is flagged in the payload" do
    ch = seed_channel_with_peers
    v = target(ch, published: NOW - 2.days) # younger than the provisional window
    set_views(v, 3000, at: NOW)

    emit(ch, now: NOW)

    assert_equal true, crossings(v).sole.payload["provisional"]
    assert_equal "relevant", crossings(v).sole.payload["band"]
  end
end
