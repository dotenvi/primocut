require "test_helper"

class CompetitorChannelTest < ActiveSupport::TestCase
  def channel(id = "UC_a")
    CompetitorChannel.create!(youtube_channel_id: id, title: "A")
  end

  test "youtube_channel_id is required and unique" do
    channel("UC_dup")
    dup = CompetitorChannel.new(youtube_channel_id: "UC_dup")
    assert_not dup.valid?
    assert_includes dup.errors[:youtube_channel_id], "has already been taken"
  end

  test "backfill_state enum: predicates and scopes" do
    c = channel
    assert c.backfill_pending?
    c.backfill_done!
    assert c.backfill_done?
    assert_includes CompetitorChannel.backfill_done, c
  end

  test "destroy cascades videos and their series" do
    c = channel
    v = c.competitor_videos.create!(youtube_video_id: "v1")
    v.video_snapshots.create!(captured_at: Time.current, views: 1)
    v.video_comments.create!(comment_id: "c1", fetched_at: Time.current)

    c.destroy

    assert_empty CompetitorVideo.where(id: v.id)
    assert_empty VideoSnapshot.where(competitor_video_id: v.id)
    assert_empty VideoComment.where(competitor_video_id: v.id)
  end

  test "destroy purges events referencing the channel OR its videos only" do
    c = channel
    v = c.competitor_videos.create!(youtube_video_id: "v1")
    by_channel = Event.create!(category: "niche", event_type: "x",
                               competitor_channel_id: c.id, occurred_at: Time.current)
    by_video = Event.create!(category: "niche", event_type: "y",
                             competitor_video_id: v.id, occurred_at: Time.current)
    other = Event.create!(category: "niche", event_type: "z",
                          competitor_channel_id: channel("UC_other").id,
                          occurred_at: Time.current)

    c.destroy

    assert_empty Event.where(id: by_channel.id), "channel-referencing event purged"
    assert_empty Event.where(id: by_video.id), "video-only event purged (ordering)"
    assert Event.exists?(other.id), "unrelated event kept"
  end
end
