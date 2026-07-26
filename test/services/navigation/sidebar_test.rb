require "test_helper"

# The navigation chrome's payload. It renders on every page, so what matters here
# is that it stays bounded: one grouped count rather than a COUNT per project, and
# a quota read scoped to the API's current day.
class Navigation::SidebarTest < ActiveSupport::TestCase
  test "lists projects by name with their tracked-channel counts" do
    poker = Project.create!(name: "Poker")
    chess = Project.create!(name: "Chess")
    2.times do |i|
      chess.project_channels.create!(
        competitor_channel: CompetitorChannel.create!(youtube_channel_id: "UC_c#{i}", title: "C#{i}")
      )
    end

    result = Navigation::Sidebar.new.call

    assert_equal %w[Chess Poker], result.projects.map(&:name)
    assert_equal 2, result.channel_count(chess)
    assert_equal 0, result.channel_count(poker), "a project with no channels still reads zero"
  end

  test "the query count does not grow with the number of projects" do
    # projects + one grouped channel count + the quota sum. The chrome renders on
    # every page, so this must stay flat, not one COUNT per project.
    Project.create!(name: "Solo")
    assert_queries_count(3) { Navigation::Sidebar.new.call }

    3.times { |i| Project.create!(name: "P#{i}") }
    assert_queries_count(3) { Navigation::Sidebar.new.call }
  end

  test "reads the quota against the API's day, which starts at midnight Pacific" do
    # 05:00 UTC on the 26th is still the 25th in Los Angeles, so a spend logged at
    # 08:00 UTC on the 25th belongs to the SAME quota day and must be counted.
    now = Time.utc(2026, 7, 26, 5, 0)
    cycle(units: 40, at: Time.utc(2026, 7, 25, 8, 0))
    cycle(units: 900, at: Time.utc(2026, 7, 25, 6, 0)) # before the Pacific turnover

    result = Navigation::Sidebar.new(now: now).call

    assert_equal 40, result.quota_used
    assert_equal Adapters::YoutubeApi::DAILY_QUOTA_UNITS, result.quota_budget
  end

  def cycle(units:, at:)
    Event.create!(category: "ops", event_type: "cycle_done", occurred_at: at,
      payload: { "quota_units" => units })
  end
end
