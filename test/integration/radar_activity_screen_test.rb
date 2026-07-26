require "test_helper"

# The global Radar (niche event feed, unseen/seen split, project filter) and
# Activity (full log) screens. A niche event carries a channel, never a project,
# so the feed has to resolve titles, badges and links on read.
class RadarActivityScreenTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Chess")
    @channel = CompetitorChannel.create!(youtube_channel_id: "UC_solo", title: "Solo", handle: "@solo")
    @project.project_channels.create!(competitor_channel: @channel)
    @video = @channel.competitor_videos.create!(youtube_video_id: "vid1", title: "A rising clip",
      published_at: 30.days.ago, thumbnail_url: "https://i.ytimg.com/vi/vid1/default.jpg")
  end

  def crossing(video: @video, occurred_at: 1.hour.ago, seen_at: nil, band: "exceptional", payload: {})
    Event.create!(category: "niche", event_type: "outlier_crossed", occurred_at:, seen_at:,
      competitor_channel_id: @channel.id, competitor_video_id: video.id,
      payload: { "band" => band, "views" => 77_619, "median_multiple" => 10.7 }.merge(payload))
  end

  test "radar shows an empty state when there are no events" do
    get root_path
    assert_response :success
    assert_select "h1", text: "Radar"
    assert_select "p", text: /Nothing on the radar yet/
  end

  test "radar names the video behind an event, with its band and metrics" do
    crossing

    get root_path
    assert_response :success
    assert_select ".lbl", text: /New · 1/
    assert_select ".ev .tag", text: "p99 exceptional"    # the band, not the raw type
    assert_select ".ev .tag", text: "Chess"              # the project badge
    assert_select ".ev", text: /A rising clip/           # the resolved video title
    assert_select ".ev", text: /77.6k views · 10.7× median/
    assert_select ".ev img[src=?]", "https://i.ytimg.com/vi/vid1/default.jpg"
  end

  test "a card links through to the video inside a project that tracks its channel" do
    crossing

    get root_path
    assert_select "a.ev[href=?]", project_niche_channel_video_path(@project, "UC_solo", "vid1")
  end

  test "an event whose video is gone still renders, without a link" do
    event = crossing
    @video.destroy!
    event.reload

    get root_path
    assert_response :success
    assert_select "a.ev", count: 0
    assert_select ".ev", text: /Outlier crossed/
  end

  test "radar splits unseen and seen niche events" do
    crossing
    old = @channel.competitor_videos.create!(youtube_video_id: "vid2", title: "An old crossing")
    crossing(video: old, occurred_at: 2.days.ago, seen_at: 1.day.ago, band: "relevant")

    get root_path
    assert_response :success
    assert_select ".ev", text: /A rising clip/
    assert_select ".ev.seen", text: /An old crossing/
    assert_select ".ev.seen .tag", text: "p90"
  end

  test "the project filter scopes the feed through the project's channels" do
    crossing
    other = Project.create!(name: "Poker")

    get root_path(project_id: other.id)
    assert_response :success
    assert_select ".ev", count: 0
    assert_select "p", text: /Nothing on the radar for Poker yet/

    get root_path(project_id: @project.id)
    assert_select ".ev", text: /A rising clip/
  end

  test "each feed pages independently" do
    8.times { |i| crossing(video: @channel.competitor_videos.create!(youtube_video_id: "n#{i}", title: "New #{i}")) }

    get root_path
    assert_select ".ev", count: Radar::Screen::NEW_PER_PAGE
    assert_select ".m", text: "1 / 2"

    get root_path(new_page: 2)
    assert_select ".ev", count: 8 - Radar::Screen::NEW_PER_PAGE # the tail of the 8
  end

  test "marking all as seen clears the New feed" do
    crossing

    post radar_seen_path(project_id: @project.id)
    assert_redirected_to root_path(project_id: @project.id)
    assert Event.category_niche.where(seen_at: nil).none?

    follow_redirect!
    assert_select ".lbl", text: /Earlier · seen · 1/
    assert_select "input[value=?]", "Mark all as seen", count: 0
  end

  test "open ops failures surface above the feed and resolved ones do not" do
    Event.create!(category: "ops", event_type: "pipeline_failed", severity: "error",
      occurred_at: 1.hour.ago, payload: { "message" => "ffmpeg exited 1" })
    Event.create!(category: "ops", event_type: "cycle_done", occurred_at: 2.hours.ago,
      resolved_at: 2.hours.ago)

    get root_path
    assert_response :success
    assert_select ".lbl.text-err", text: "Needs you · 1"
    assert_select "span", text: "ffmpeg exited 1"
  end

  test "activity lists the log and shows an unknown quota" do
    Event.create!(category: "ops", event_type: "quota_exhausted", severity: "error", occurred_at: 1.hour.ago)

    get activity_path
    assert_response :success
    assert_select "h1", text: "Activity"
    assert_select "td.font-mono", text: "quota_exhausted"
    assert_select "span.text-ok", text: "—" # quota tracking is Phase 3
  end
end
