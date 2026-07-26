require "test_helper"

# Adding and removing the channels you publish to. The normalisation and the
# project scoping live here rather than in a request, so they hold for any caller.
class Settings::OwnChannelsTest < ActiveSupport::TestCase
  setup { @project = Project.create!(name: "Chess") }

  def add(**attributes)
    Settings::AddOwnChannel.new.call(project: @project, attributes: attributes)
  end

  test "adds a channel to the project" do
    channel = add(channel_url: "youtube.com/@mine", handle: "@mine", role: "main")

    assert channel.persisted?
    assert_equal [ channel ], @project.own_channels.to_a
  end

  test "strips the whitespace around what was typed" do
    channel = add(channel_url: "  youtube.com/@mine  ", handle: " @mine ", role: " main ")

    assert_equal "youtube.com/@mine", channel.channel_url
    assert_equal "@mine", channel.handle
    assert_equal "main", channel.role
  end

  test "a blank role is stored as absent, not as an empty string" do
    assert_nil add(channel_url: "u/1", role: "   ").role
    assert_nil add(channel_url: "u/2").role
  end

  test "ignores fields a person does not supply" do
    # `title` is stored but never typed — it must not be settable from outside.
    channel = add(channel_url: "u/1", title: "injected", project_id: 999)

    assert_equal "", channel.title
    assert_equal @project.id, channel.project_id
  end

  test "a rejected channel comes back unsaved, carrying its reasons" do
    add(channel_url: "youtube.com/@mine")
    duplicate = add(channel_url: "youtube.com/@mine")

    assert_not duplicate.persisted?
    assert_predicate duplicate.errors, :any?
    assert_equal 1, @project.own_channels.count
  end

  test "the same url may belong to another project" do
    add(channel_url: "youtube.com/@mine")
    other = Project.create!(name: "Poker")

    channel = Settings::AddOwnChannel.new.call(project: other, attributes: { channel_url: "youtube.com/@mine" })

    assert channel.persisted?
  end

  test "removing returns the record so the confirmation can still name it" do
    channel = add(channel_url: "youtube.com/@mine", handle: "@mine")

    removed = Settings::RemoveOwnChannel.new.call(project: @project, id: channel.id)

    assert_equal "@mine", removed.handle
    assert_empty @project.own_channels.reload
  end

  test "another project's channel does not exist here" do
    other = Project.create!(name: "Poker")
    theirs = other.own_channels.create!(channel_url: "youtube.com/@theirs")

    assert_raises(ActiveRecord::RecordNotFound) do
      Settings::RemoveOwnChannel.new.call(project: @project, id: theirs.id)
    end
    assert theirs.reload.persisted?
  end
end
