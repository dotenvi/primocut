require "test_helper"

# The Settings payload. The band half is the one worth pinning: it comes from the
# global config, so a project must never be able to shift it.
class Settings::ScreenTest < ActiveSupport::TestCase
  setup { @project = Project.create!(name: "Chess") }

  test "lists this project's channels by handle" do
    @project.own_channels.create!(channel_url: "u/z", handle: "@zulu")
    @project.own_channels.create!(channel_url: "u/a", handle: "@alpha")
    Project.create!(name: "Poker").own_channels.create!(channel_url: "u/x", handle: "@theirs")

    assert_equal %w[@alpha @zulu], Settings::Screen.new(@project).call.own_channels.map(&:handle)
  end

  test "reports the global bands under the percentile basis" do
    result = Settings::Screen.new(@project).call

    assert result.percentile?
    assert_equal 90.0, result.cutoff("relevant")
    assert_equal 97.0, result.cutoff("strong")
    assert_equal 99.0, result.cutoff("exceptional")
  end

  test "the fixed basis reports multiples instead of ranks" do
    result = Settings::Screen.new(@project, config: Metrics::Config.new(band_basis: "fixed")).call

    assert_not result.percentile?
    assert_equal 3.0, result.cutoff("relevant")
    assert_equal 10.0, result.cutoff("exceptional")
  end

  test "every project reads the same bands" do
    other = Project.create!(name: "Poker")

    assert_equal Settings::Screen.new(@project).call.cutoffs,
      Settings::Screen.new(other).call.cutoffs,
      "bands are global — two niches must stay comparable"
  end
end
