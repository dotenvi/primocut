require "test_helper"

# Phase-1 shell smoke tests: the layout, sidebar and navigation render end to
# end. Content is still placeholder (Phase 2), so these assert the chrome and the
# routing wiring, not any real dashboard data.
class NavigationShellTest < ActionDispatch::IntegrationTest
  test "radar is the root and renders inside the shell" do
    get root_path
    assert_response :success
    assert_select "aside a", text: /PRIMOCUT/          # sidebar brand
    assert_select "h1", text: "Radar"
  end

  test "activity renders" do
    get activity_path
    assert_response :success
    assert_select "h1", text: "Activity"
  end

  test "the sidebar lists projects and links to their sections" do
    project = Project.create!(name: "Chess")

    get root_path
    assert_response :success
    assert_select "aside", text: /Chess/
    assert_select "a[href=?]", project_niche_path(project)
    assert_select "a[href=?]", project_sources_path(project)
    assert_select "a[href=?]", project_settings_path(project)
  end

  test "per-project screens render with the project in context" do
    project = Project.create!(name: "Chess")

    get project_niche_path(project)
    assert_response :success
    assert_select "h1", text: "Niche"
    assert_select ".eyebrow", text: "Chess"

    get project_sources_path(project)
    assert_response :success
    assert_select "h1", text: "Cut Room"

    get project_settings_path(project)
    assert_response :success
    assert_select "h1", text: "Settings"
  end

  test "the sidebar reads today's quota against the daily budget" do
    Event.create!(category: "ops", event_type: "cycle_done", occurred_at: 10.minutes.ago,
      payload: { "quota_units" => 240 })
    Event.create!(category: "ops", event_type: "cycle_done", occurred_at: 3.days.ago,
      payload: { "quota_units" => 9_000 })

    get root_path
    assert_response :success
    # Yesterday's spend is not today's: the API budget resets daily.
    assert_select "aside span.text-ok", text: /240 \/ 10,000/
  end

  test "an unknown project is not found" do
    get project_niche_path(project_id: 0)
    assert_response :not_found
  end
end
