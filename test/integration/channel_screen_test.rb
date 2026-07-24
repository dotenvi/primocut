require "test_helper"

# The Channel dashboard screen renders the ChannelDashboard payload: header stats,
# baselines, engagement, cadence and the per-format outlier ranking. It is reachable
# only for a channel tracked by the project (leakage guard).
class ChannelScreenTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Chess")
    @channel = CompetitorChannel.create!(youtube_channel_id: "UC_king", title: "King", handle: "@king")
    @project.project_channels.create!(competitor_channel: @channel)
    @channel.channel_snapshots.create!(captured_at: Time.current, subscribers: 2_000_000, total_views: 500_000_000, video_count: 412)
    @seq = 0
    10.times { video(views: 1000) }
    video(views: 1_000_000, title: "The Viral")
  end

  def video(views:, title: nil)
    @seq += 1
    v = @channel.competitor_videos.create!(
      youtube_video_id: "v#{@seq}", title: title || "V#{@seq}", published_at: 60.days.ago
    )
    v.video_snapshots.create!(captured_at: 1.hour.ago, views:)
    v
  end

  test "renders header stats and the outlier ranking" do
    get project_niche_channel_path(@project, "UC_king")
    assert_response :success
    assert_select "h1", text: "King"
    assert_select "p.m", text: /2M subscribers/
    assert_select "td", text: /The Viral/
    assert_select "span.tag", text: "p99"
  end

  test "is reachable from the niche channels tab" do
    get project_niche_path(@project, tab: "channels")
    assert_select "a[href=?]", project_niche_channel_path(@project, "UC_king"), text: "King"
  end

  test "a channel not tracked by the project is not found" do
    other = CompetitorChannel.create!(youtube_channel_id: "UC_other", title: "Other")
    get project_niche_channel_path(@project, other.youtube_channel_id)
    assert_response :not_found
  end
end
