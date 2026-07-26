require "test_helper"

# The Channels tab's payload. What matters is that it stays cheap — it is polled
# every couple of seconds while a backfill runs — and that it reports collection
# progress honestly while the totals are still unknown.
class Competitors::ChannelListTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Chess")
  end

  def track(title:, handle: "", state: "done", done: 0, total: 0, error: nil)
    channel = CompetitorChannel.create!(
      youtube_channel_id: "UC_#{title.parameterize(separator: '_')}", title: title, handle: handle,
      backfill_state: state, backfill_done: done, backfill_total: total, backfill_error: error
    )
    @project.project_channels.create!(competitor_channel: channel)
    channel
  end

  test "lists the project's channels by title with their identity" do
    track(title: "Zulu", handle: "@zulu")
    track(title: "Alpha")

    rows = Competitors::ChannelList.new(@project).call

    assert_equal %w[Alpha Zulu], rows.map(&:title)
    assert_nil rows.first.handle, "a channel with no handle reads as absent, not as an empty string"
    assert_equal "@zulu", rows.last.handle
  end

  test "reports the most recent subscriber count" do
    channel = track(title: "Solo")
    channel.channel_snapshots.create!(captured_at: 2.days.ago, subscribers: 1_000)
    channel.channel_snapshots.create!(captured_at: 1.hour.ago, subscribers: 12_345)

    assert_equal 12_345, Competitors::ChannelList.new(@project).call.first.subscribers
  end

  test "a channel never snapshotted has no subscriber count" do
    track(title: "Solo")

    assert_nil Competitors::ChannelList.new(@project).call.first.subscribers
  end

  test "a backfill that has not counted the uploads yet has no expected total" do
    track(title: "Solo", state: "running", done: 3, total: 0)

    row = Competitors::ChannelList.new(@project).call.first

    assert row.collecting?
    assert_equal 3, row.collected
    assert_nil row.expected, "0 means unknown, and must not render as a total of zero"
  end

  test "queued and running are in flight, everything else has settled" do
    states = { "pending" => false, "queued" => true, "running" => true,
               "done" => false, "error" => false, "skipped" => false }

    states.each do |state, collecting|
      channel = track(title: "Ch #{state}", state: state)
      row = Competitors::ChannelList.new(@project).call.find { |r| r.id == channel.id }
      assert_equal collecting, row.collecting?, "#{state} should#{" not" unless collecting} poll"
    end
  end

  test "another project's channels are not listed" do
    track(title: "Mine")
    other = Project.create!(name: "Poker")
    theirs = CompetitorChannel.create!(youtube_channel_id: "UC_theirs", title: "Theirs")
    other.project_channels.create!(competitor_channel: theirs)

    assert_equal %w[Mine], Competitors::ChannelList.new(@project).call.map(&:title)
  end

  test "the query count does not grow with the number of channels" do
    track(title: "One")
    assert_queries_count(2) { Competitors::ChannelList.new(@project).call } # channels + snapshots

    3.times { |i| track(title: "Ch#{i}") }
    assert_queries_count(2) { Competitors::ChannelList.new(@project).call }
  end
end
