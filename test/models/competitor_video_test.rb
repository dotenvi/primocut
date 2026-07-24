require "test_helper"

class CompetitorVideoTest < ActiveSupport::TestCase
  setup do
    @channel = CompetitorChannel.create!(youtube_channel_id: "UC_v")
  end

  test "youtube_video_id is required and unique" do
    @channel.competitor_videos.create!(youtube_video_id: "dup")
    dup = CompetitorVideo.new(youtube_video_id: "dup", competitor_channel: @channel)
    assert_not dup.valid?
  end

  test "video_attributes unique per source, attrs is jsonb" do
    v = @channel.competitor_videos.create!(youtube_video_id: "v1")
    v.video_attributes.create!(source: "syntactic", attrs: { "caps" => true })
    again = v.video_attributes.build(source: "syntactic")
    assert_not again.valid?, "one row per (video, source)"
    assert_equal true, v.video_attributes.first.attrs["caps"]
  end

  test "video_attributes source and state enums" do
    v = @channel.competitor_videos.create!(youtube_video_id: "v2")
    a = v.video_attributes.create!(source: "title_llm", state: "running")
    assert a.source_title_llm?
    assert a.state_running?
  end
end
