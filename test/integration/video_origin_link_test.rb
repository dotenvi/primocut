require "test_helper"

# The video screen is reached from four places, but its back link only ever named
# the channel — arriving from the Radar and leaving through it dumps you on a
# channel you never visited, and loses your place in the feed. The origin travels
# as structured params, and the one back link points at it.
class VideoOriginLinkTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Chess")
    @channel = CompetitorChannel.create!(youtube_channel_id: "UC_solo", title: "Solo", handle: "@solo")
    @project.project_channels.create!(competitor_channel: @channel)
    @video = @channel.competitor_videos.create!(youtube_video_id: "vid1", title: "A rising clip",
      published_at: 30.days.ago)
    @video.video_snapshots.create!(captured_at: 1.hour.ago, views: 1000)
    @path = project_niche_channel_video_path(@project, "UC_solo", "vid1")
  end

  # The one link on the screen, whatever it currently points at.
  def back_links
    css_select "a.eyebrow"
  end

  test "no origin falls back to the hierarchy" do
    get @path
    assert_response :success
    assert_equal 1, back_links.size
    assert_select "a[href=?]", project_niche_channel_path(@project, "UC_solo"), text: "‹ Niche / channel"
  end

  test "arriving from the Radar points the back link at it, replacing the breadcrumb" do
    get @path, params: { from: "radar" }
    assert_response :success
    assert_equal 1, back_links.size
    assert_select "a[href=?]", root_path, text: "‹ Radar"
    assert_select "a", text: "‹ Niche / channel", count: 0
  end

  test "the way back keeps the feed page and the project filter" do
    get @path, params: { from: "radar", np: "2", sp: "3", rf: "1" }
    assert_select "a[href=?]", root_path(project_id: @project.id, new_page: 2, seen_page: 3), text: "‹ Radar"
  end

  test "an unfiltered Radar comes back unfiltered" do
    get @path, params: { from: "radar", np: "2" }
    assert_select "a[href=?]", root_path(new_page: 2), text: "‹ Radar"
  end

  test "arriving from the niche outliers returns to that tab and format" do
    get @path, params: { from: "niche", fmt: "short" }
    assert_response :success
    assert_equal 1, back_links.size
    assert_select "a[href=?]", project_niche_path(@project, tab: "outliers", fmt: "short"),
      text: "‹ Niche / outliers"
  end

  test "an unknown origin falls back to the hierarchy rather than being rendered" do
    get @path, params: { from: "https://evil.example.com" }
    assert_response :success
    assert_equal 1, back_links.size
    assert_select "a[href=?]", project_niche_channel_path(@project, "UC_solo"), text: "‹ Niche / channel"
    assert_select "a[href*=?]", "evil.example.com", count: 0
  end

  test "the way back is rebuilt, never taken from the url" do
    # A crafted origin cannot point the back link off-site: nothing in the query
    # string is used as a path, only as a whitelisted key and clamped numbers.
    get @path, params: { from: "radar", np: "-9", sp: "abc", rf: "https://evil.example.com" }
    assert_response :success
    assert_select "a[href=?]", root_path(project_id: @project.id), text: "‹ Radar"
  end
end
