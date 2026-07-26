require "test_helper"

# Tracking a competitor channel. The API client arrives through the constructor,
# so this never touches the network and needs no key in the environment — the
# whole reason the wiring lives here and not in a controller.
class Competitors::TrackChannelTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup { @project = Project.create!(name: "Chess") }

  # Answers `get_channel` with a fixed resolution, and records that it was asked.
  class FakeYouTube
    attr_reader :asked

    def initialize(info)
      @info = info
      @asked = []
    end

    def get_channel(**kwargs)
      @asked << kwargs
      @info
    end
  end

  def info(id: "UC_new", title: "Newbie", handle: "@newbie")
    Adapters::YoutubeApi::ChannelInfo.new(channel_id: id, title: title, handle: handle,
      uploads_playlist_id: "UU_new")
  end

  test "resolves the reference, links the channel and queues its collection" do
    client = FakeYouTube.new(info)

    result = nil
    assert_enqueued_with(job: Competitors::ChannelBackfillJob) do
      result = Competitors::TrackChannel.new(client: client).call(project: @project, reference: "@newbie")
    end

    assert_equal [ { handle: "@newbie" } ], client.asked
    channel = CompetitorChannel.find_by(youtube_channel_id: "UC_new")
    assert_equal "Newbie", channel.title
    assert channel.backfill_queued?
    assert @project.competitor_channels.exists?(channel.id)
    assert_not result[:existing]
  end

  test "a channel already collected elsewhere is linked without re-collecting" do
    known = CompetitorChannel.create!(youtube_channel_id: "UC_new", title: "Newbie", backfill_state: "done")
    Project.create!(name: "Poker").project_channels.create!(competitor_channel: known)

    result = nil
    assert_no_enqueued_jobs only: Competitors::ChannelBackfillJob do
      result = Competitors::TrackChannel.new(client: FakeYouTube.new(info)).call(project: @project, reference: "@newbie")
    end

    assert result[:existing]
    assert_equal "skipped", result[:backfill]
    assert @project.competitor_channels.exists?(known.id)
  end

  test "tracking the same channel twice does not link it twice" do
    2.times do
      Competitors::TrackChannel.new(client: FakeYouTube.new(info)).call(project: @project, reference: "@newbie")
    end

    assert_equal 1, @project.project_channels.count
  end

  test "an empty reference is refused before anything is written" do
    client = FakeYouTube.new(info)

    assert_no_difference -> { CompetitorChannel.count } do
      error = assert_raises(Competitors::TrackChannel::Failed) do
        Competitors::TrackChannel.new(client: client).call(project: @project, reference: "")
      end
      assert_match(/reference/i, error.message)
    end

    assert_empty client.asked, "a reference that cannot be parsed must not cost an API call"
  end

  test "a bug in the stack is not disguised as a bad reference" do
    # Failed is for the two things a user can cause. Anything else must crash
    # loudly instead of arriving as a polite flash message.
    exploding = Object.new
    exploding.define_singleton_method(:register) { |**| raise ArgumentError, "wrong number of arguments" }

    assert_raises(ArgumentError) do
      Competitors::TrackChannel.new(registration: exploding).call(project: @project, reference: "@newbie")
    end
  end

  test "no environment key is needed when a client is injected" do
    # The default is only evaluated when no client is supplied, so a test never
    # trips over a missing YOUTUBE_API_KEY.
    original = ENV.delete("YOUTUBE_API_KEY")

    assert_nothing_raised do
      Competitors::TrackChannel.new(client: FakeYouTube.new(info)).call(project: @project, reference: "@newbie")
    end
  ensure
    ENV["YOUTUBE_API_KEY"] = original if original
  end
end
