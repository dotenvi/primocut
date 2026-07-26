require "test_helper"

# The Activity log: every event, newest first, naming what it was about, what it
# spent and whether it worked. Paginated by a descending-id cursor, because the
# log only ever grows at the head.
class ActivityScreenTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Chess")
    @channel = CompetitorChannel.create!(youtube_channel_id: "UC_solo", title: "Solo", handle: "@solo")
    @project.project_channels.create!(competitor_channel: @channel)
    @video = @channel.competitor_videos.create!(youtube_video_id: "vid1", title: "A rising clip")
  end

  def event(type:, category: "ops", severity: "info", occurred_at: 1.hour.ago,
            resolved_at: nil, payload: {}, video: nil)
    Event.create!(category: category, event_type: type, severity: severity,
      occurred_at: occurred_at, resolved_at: resolved_at, payload: payload,
      competitor_video_id: video&.id, competitor_channel_id: (@channel.id if video))
  end

  test "shows an empty state before anything has run" do
    get activity_path
    assert_response :success
    assert_select "h1", text: "Activity"
    assert_select "p", text: /No activity recorded yet/
  end

  test "a row names the job, its subject and its result" do
    event(type: "outlier_crossed", category: "niche", video: @video)

    get activity_path
    assert_response :success
    assert_select "td", text: "outlier crossed"     # the type, humanised
    assert_select "td", text: "A rising clip"       # the subject, resolved
    assert_select "td .tag.text-ok", text: "ok"
  end

  test "a cycle event names the scope it ran and the quota it spent" do
    event(type: "cycle_done", resolved_at: 1.hour.ago,
          payload: { "scope" => "recent", "quota_units" => 11 })

    get activity_path
    assert_select "td", text: "recent"              # no subject — the payload's scope
    assert_select "td", text: "11"
  end

  test "events that spend nothing show a muted dash, not a zero" do
    event(type: "outlier_crossed", category: "niche", video: @video)

    get activity_path
    assert_select "td.text-ink-3", text: "—"
  end

  test "the quota accounting sums every cycle" do
    event(type: "cycle_done", payload: { "quota_units" => 11 }, resolved_at: 1.hour.ago)
    event(type: "cycle_done", payload: { "quota_units" => 9 }, resolved_at: 2.hours.ago)
    event(type: "outlier_crossed", category: "niche", payload: { "quota_units" => 999 })

    get activity_path
    assert_select "div.m", text: /^20 quota units accounted/
  end

  test "an unresolved failure reads as an error, naming its stage" do
    event(type: "pipeline_failed", severity: "error", payload: { "stage" => "transcription" })

    get activity_path
    assert_select "td .tag.text-err", text: "transcription"
  end

  test "a failure that was resolved is history, not an open error" do
    event(type: "pipeline_failed", severity: "error", resolved_at: 1.minute.ago)

    get activity_path
    assert_select "td .tag.text-err", count: 0
    assert_select "td .tag.text-ok", text: "ok"
  end

  test "days are named once instead of on every row" do
    event(type: "cycle_done", occurred_at: 1.hour.ago, resolved_at: 1.hour.ago)
    event(type: "cycle_done", occurred_at: 2.hours.ago, resolved_at: 2.hours.ago)
    event(type: "cycle_done", occurred_at: 3.days.ago, resolved_at: 3.days.ago)

    get activity_path
    assert_select "td[colspan=?] .lbl", "5", count: 2   # today, and the older day
    assert_select "td[colspan=?] .lbl", "5", text: "Today"
  end

  test "the cursor pages backwards through the log" do
    # Appended oldest-first, so the first event carries the lowest id — the cursor
    # rides the id, which is what makes it stable as the log grows at the head.
    events = 3.times.map { |i| event(type: "cycle_done", occurred_at: (3 - i).hours.ago, resolved_at: 1.hour.ago) }

    get activity_path(before_id: events.last.id)
    assert_response :success
    assert_select "tbody tr td .tag", count: 2         # the two appended before it

    get activity_path(before_id: events.first.id)
    assert_select "p", text: /Nothing older than this/
    assert_select "a", text: "‹ Newest"
  end

  test "the first page offers no way back to itself" do
    event(type: "cycle_done", resolved_at: 1.hour.ago)

    get activity_path
    assert_select "a", text: "‹ Newest", count: 0
  end
end
