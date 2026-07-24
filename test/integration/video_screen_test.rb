require "test_helper"

# The Video detail screen renders the VideoReport payload: standing (band, multiple,
# baseline), the channel spread strip, velocity, packaging features, and links out.
# Reachable only through the project → channel → video chain (leakage guard).
class VideoScreenTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Chess")
    @channel = CompetitorChannel.create!(youtube_channel_id: "UC_king", title: "King")
    @project.project_channels.create!(competitor_channel: @channel)
    @seq = 0
    10.times { video(views: 1000) }
    @viral = video(views: 1_000_000, title: "The Viral?")
    @viral.video_snapshots.create!(captured_at: 1.hour.ago, views: 1_100_000, likes: 88_000, comments: 4400)
    @viral.video_attributes.create!(source: Metrics::Attributes::SOURCE, state: "done",
      attrs: Metrics::Attributes.syntactic_attributes(@viral.title))
  end

  def video(views:, title: nil)
    @seq += 1
    v = @channel.competitor_videos.create!(
      youtube_video_id: "v#{@seq}", title: title || "V#{@seq}", published_at: 60.days.ago
    )
    v.video_snapshots.create!(captured_at: 2.hours.ago, views:)
    v
  end

  def path_for(video) = project_niche_channel_video_path(@project, "UC_king", video.youtube_video_id)

  test "renders standing, velocity and packaging features" do
    get path_for(@viral)
    assert_response :success
    assert_select "h1", text: "The Viral?"
    assert_select "span.tag", text: /exceptional/          # band standing
    assert_select ".pat", text: /has_question/            # a syntactic packaging feature
    assert_select "a.btn", text: /Open on YouTube/
  end

  test "is reachable from the channel outlier list" do
    get project_niche_channel_path(@project, "UC_king", fmt: "long")
    assert_select "a[href=?]", path_for(@viral), text: /The Viral/
  end

  test "a video not in the channel is not found" do
    get project_niche_channel_video_path(@project, "UC_king", "nope")
    assert_response :not_found
  end
end
