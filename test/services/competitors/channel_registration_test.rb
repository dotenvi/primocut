require "test_helper"

# Tests for channel registration + detach (YouTube + queue faked, no network).
# Covers: new-channel link + backfill enqueue, cross-project dedup (2nd project
# only links), orphan reactivation, an unreachable queue leaving the channel in
# `error`, the retry of a never-collected channel, no retry of a finished one,
# and detach preserving data. Ported from the PoC `tests/test_channel_backfill.py`.
class Competitors::ChannelRegistrationTest < ActiveSupport::TestCase
  Api = Adapters::YoutubeApi
  CHAN_ID = "UCchan0000000000000000".freeze
  Job = Struct.new(:job_id)

  class FakeYouTube
    attr_reader :units_used

    def initialize(info)
      @info = info
      @units_used = 0
    end

    def get_channel(**_kwargs)
      @units_used += 1
      @info
    end
  end

  def channel_info
    Api::ChannelInfo.new(channel_id: CHAN_ID, title: "Chan", handle: "@chan", uploads_playlist_id: "UUchan")
  end

  def client = FakeYouTube.new(channel_info)

  # Records the channels it was asked to enqueue and hands back a job id.
  def recording_enqueuer
    calls = []
    [ calls, ->(channel) { calls << channel.youtube_channel_id; Job.new("bf-#{calls.size}") } ]
  end

  # A queue whose broker is unreachable — mirrors Redis being down.
  def dead_enqueuer = ->(_channel) { raise SocketError, "Error 111 connecting to localhost:6379. Connection refused." }

  test "register new channel links and enqueues backfill" do
    project = Project.create!(name: "P")
    calls, enqueuer = recording_enqueuer

    res = Competitors::ChannelRegistration.new(client:, enqueuer:).register(project_id: project.id, reference: "@chan")

    assert_equal false, res[:existing]
    assert_equal "queued", res[:backfill]
    assert_equal true, res[:linked]
    assert_equal [ CHAN_ID ], calls
    ch = CompetitorChannel.find_by(youtube_channel_id: CHAN_ID)
    assert ch.active?
    assert ch.backfill_queued?
    assert_equal "bf-1", ch.backfill_rq_job_id
  end

  test "register existing channel dedups with no backfill" do
    p1 = Project.create!(name: "P1")
    p2 = Project.create!(name: "P2")
    _calls, enqueuer = recording_enqueuer
    Competitors::ChannelRegistration.new(client:, enqueuer:).register(project_id: p1.id, reference: "@chan")

    calls2, enqueuer2 = recording_enqueuer
    res = Competitors::ChannelRegistration.new(client:, enqueuer: enqueuer2).register(project_id: p2.id, reference: "@chan")

    assert_equal true, res[:existing]
    assert_equal "skipped", res[:backfill]
    assert_empty calls2 # no re-collection
    assert_equal 2, ProjectChannel.where(competitor_channel: CompetitorChannel.find_by(youtube_channel_id: CHAN_ID)).count
  end

  test "register reactivates an orphaned channel" do
    project = Project.create!(name: "P")
    CompetitorChannel.create!(youtube_channel_id: CHAN_ID, uploads_playlist_id: "UUchan", active: false, backfill_state: "done")
    _calls, enqueuer = recording_enqueuer

    res = Competitors::ChannelRegistration.new(client:, enqueuer:).register(project_id: project.id, reference: "@chan")

    assert_equal true, res[:existing]
    assert_equal true, res[:reactivated]
    assert CompetitorChannel.find_by(youtube_channel_id: CHAN_ID).active?
  end

  test "register marks error when the queue is unreachable" do
    project = Project.create!(name: "P")

    assert_raises(Competitors::QueueUnavailableError) do
      Competitors::ChannelRegistration.new(client:, enqueuer: dead_enqueuer).register(project_id: project.id, reference: "@chan")
    end

    ch = CompetitorChannel.find_by(youtube_channel_id: CHAN_ID)
    assert ch.backfill_error?
    assert_includes ch.backfill_error, "6379" # the broker failure is reported
    assert_nil ch.backfill_rq_job_id
  end

  test "register retries the backfill of a never-collected channel" do
    project = Project.create!(name: "P")
    assert_raises(Competitors::QueueUnavailableError) do
      Competitors::ChannelRegistration.new(client:, enqueuer: dead_enqueuer).register(project_id: project.id, reference: "@chan")
    end

    calls, enqueuer = recording_enqueuer # broker back up, same reference + project
    res = Competitors::ChannelRegistration.new(client:, enqueuer:).register(project_id: project.id, reference: "@chan")

    assert_equal true, res[:existing]
    assert_equal "queued", res[:backfill]
    assert_equal [ CHAN_ID ], calls
    ch = CompetitorChannel.find_by(youtube_channel_id: CHAN_ID)
    assert ch.backfill_queued?
    assert_nil ch.backfill_error # the previous failure is cleared
    assert_equal 1, ProjectChannel.where(competitor_channel: ch).count # no dup link
  end

  test "register does not retry an already-collected channel" do
    project = Project.create!(name: "P")
    CompetitorChannel.create!(youtube_channel_id: CHAN_ID, uploads_playlist_id: "UUchan", backfill_state: "done")
    calls, enqueuer = recording_enqueuer

    res = Competitors::ChannelRegistration.new(client:, enqueuer:).register(project_id: project.id, reference: "@chan")

    assert_equal true, res[:existing]
    assert_equal "skipped", res[:backfill]
    assert_empty calls
  end

  test "register raises for a missing project" do
    _calls, enqueuer = recording_enqueuer
    assert_raises(KeyError) do
      Competitors::ChannelRegistration.new(client:, enqueuer:).register(project_id: 999, reference: "@chan")
    end
  end

  test "detach preserves backfilled videos and deactivates the orphan" do
    project = Project.create!(name: "P")
    ch = CompetitorChannel.create!(youtube_channel_id: CHAN_ID, uploads_playlist_id: "UUchan")
    ProjectChannel.create!(project:, competitor_channel: ch)
    ch.competitor_videos.create!(youtube_video_id: "v1")

    res = Competitors::ChannelRegistration.detach(project_id: project.id, youtube_channel_id: CHAN_ID)

    assert_equal true, res[:detached]
    assert_equal true, res[:deactivated]
    assert_equal 1, ch.competitor_videos.count
    assert_not ch.reload.active?
  end
end
