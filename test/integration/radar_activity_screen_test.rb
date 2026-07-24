require "test_helper"

# The global Radar (niche event feed, unseen/seen split) and Activity (full log)
# screens. Events are emitted in Phase 3, so both degrade to an honest empty state.
class RadarActivityScreenTest < ActionDispatch::IntegrationTest
  test "radar shows an empty state when there are no events" do
    get root_path
    assert_response :success
    assert_select "h1", text: "Radar"
    assert_select ".card", text: /Nothing on the radar yet/
  end

  test "radar splits unseen and seen niche events" do
    Event.create!(category: "niche", event_type: "outlier_crossed", occurred_at: 1.hour.ago,
      payload: { "title" => "A rising clip" })
    Event.create!(category: "niche", event_type: "outlier_crossed", occurred_at: 2.days.ago,
      seen_at: 1.day.ago, payload: { "title" => "An old crossing" })

    get root_path
    assert_response :success
    assert_select ".lbl", text: "New"
    assert_select ".ev", text: /A rising clip/
    assert_select ".ev.seen", text: /An old crossing/
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
