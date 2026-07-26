require "test_helper"

# The project Settings screen: the channels you publish to in this niche (which
# you edit), and the outlier bands the whole app scores against (which you cannot,
# because they are global).
class SettingsScreenTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Chess")
    @path = project_settings_path(@project)
  end

  def own(url: "youtube.com/@mine", handle: "@mine", role: "main")
    @project.own_channels.create!(channel_url: url, handle: handle, role: role)
  end

  test "an empty niche says so and still offers the form" do
    get @path
    assert_response :success
    assert_select "h1", text: "Settings"
    assert_select "p", text: /No own channel yet/
    assert_select "form[action=?]", project_settings_channels_path(@project)
  end

  test "lists the channels with their role" do
    own
    own(url: "youtube.com/@second", handle: "@second", role: "shorts")

    get @path
    assert_select ".kv", text: /@mine/
    assert_select ".kv .m", text: "main"
    assert_select ".kv .m", text: "shorts"
  end

  test "a channel with no role reads as absent, not blank" do
    own(role: nil)

    get @path
    assert_select ".kv .m", text: "—"
  end

  test "adding a channel keeps it in this project" do
    assert_difference -> { @project.own_channels.count }, 1 do
      post project_settings_channels_path(@project),
        params: { own_channel: { channel_url: "youtube.com/@mine", handle: "@mine", role: "main" } }
    end

    assert_redirected_to @path
    follow_redirect!
    assert_select ".text-ok", text: /Added @mine/
  end

  test "the same channel twice is refused with the reason" do
    own

    assert_no_difference -> { @project.own_channels.count } do
      post project_settings_channels_path(@project),
        params: { own_channel: { channel_url: "youtube.com/@mine", handle: "@mine" } }
    end

    follow_redirect!
    assert_select ".text-err", text: /already been taken/i
  end

  test "a channel with no url is refused" do
    assert_no_difference -> { @project.own_channels.count } do
      post project_settings_channels_path(@project), params: { own_channel: { handle: "@nourl" } }
    end

    follow_redirect!
    assert_select ".text-err"
  end

  test "the same url may belong to another project" do
    other = Project.create!(name: "Poker")
    other.own_channels.create!(channel_url: "youtube.com/@mine", handle: "@mine")

    assert_difference -> { @project.own_channels.count }, 1 do
      post project_settings_channels_path(@project),
        params: { own_channel: { channel_url: "youtube.com/@mine", handle: "@mine" } }
    end
  end

  test "removing a channel takes it off the list" do
    channel = own

    assert_difference -> { @project.own_channels.count }, -1 do
      delete project_settings_channel_path(@project, channel)
    end

    follow_redirect!
    assert_select ".text-ok", text: /Removed @mine/
  end

  test "another project's channel cannot be removed through this one" do
    other = Project.create!(name: "Poker")
    theirs = other.own_channels.create!(channel_url: "youtube.com/@theirs", handle: "@theirs")

    assert_no_difference -> { OwnChannel.count } do
      delete project_settings_channel_path(@project, theirs)
    end

    assert_response :not_found
  end

  test "the bands are shown in the basis they are measured in" do
    get @path
    assert_response :success
    assert_select ".kv", text: /Relevant/
    assert_select ".font-mono.text-heat-90", text: "p90"    # not "p90.0"
    assert_select ".font-mono.text-heat-97", text: "p97"
    assert_select ".font-mono.text-heat-99", text: "p99"
    assert_select "p", text: /Percentile recalibrates per channel/
  end

  test "the bands are read-only — they are global, not per project" do
    get @path
    assert_select "p", text: /global setting, applied identically to every niche/
    # No form ever posts a band: a per-project cutoff would make two niches'
    # outliers incomparable.
    assert_select "form[action=?]", project_settings_path(@project), count: 0
  end
end
