require "test_helper"

# The Niche screen's Channels tab: the operational one. It tracks a competitor,
# shows its collection progress live, and detaches it without losing data.
class NicheChannelsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @project = Project.create!(name: "Chess")
    @path = project_niche_path(@project, tab: "channels")
  end

  def track(title: "Solo", handle: "@solo", state: "done", done: 12, total: 12)
    channel = CompetitorChannel.create!(youtube_channel_id: "UC_solo", title: title, handle: handle,
      backfill_state: state, backfill_done: done, backfill_total: total)
    @project.project_channels.create!(competitor_channel: channel)
    channel
  end

  # Registration resolves the reference against the API before writing anything,
  # so the request tests hand TrackChannel a fake client through its constructor —
  # the seam that exists precisely so no controller builds its own.
  def stub_youtube(info, &block)
    client = Object.new
    client.define_singleton_method(:get_channel) { |**| info }
    tracker = Competitors::TrackChannel.new(client: client)
    stubbing(Competitors::TrackChannel, :new, tracker, &block)
  end

  def channel_info(id: "UC_new", title: "Newbie", handle: "@newbie")
    Adapters::YoutubeApi::ChannelInfo.new(channel_id: id, title: title, handle: handle,
      uploads_playlist_id: "UU_new")
  end

  test "lists a tracked channel with its handle, reach and collection" do
    channel = track
    channel.channel_snapshots.create!(captured_at: 1.hour.ago, subscribers: 12_345)

    get @path
    assert_response :success
    assert_select "td", text: "Solo"
    assert_select "td", text: "@solo"
    assert_select "td.font-mono", text: "12.3k"
    assert_select "td .m", text: "12 videos"
  end

  test "an empty niche says so and still offers the form" do
    get @path
    assert_response :success
    assert_select "p", text: /No competitor tracked yet/
    assert_select "form[action=?]", project_niche_channels_path(@project)
  end

  test "a settled list does not poll" do
    track(state: "done")

    get @path
    assert_select "turbo-frame#niche_channels:not([src])"
    assert_select "turbo-frame#niche_channels[data-controller=?]", "poll", count: 0
  end

  test "a collecting channel shows live progress and polls for it" do
    track(state: "running", done: 3, total: 40)

    get @path
    assert_select "turbo-frame#niche_channels[src=?]", project_niche_channels_path(@project)
    assert_select "turbo-frame#niche_channels[data-controller=?]", "poll"
    assert_select "td .text-accent", text: "3/40"
  end

  test "a backfill that has not counted the uploads yet reads as unknown" do
    track(state: "running", done: 3, total: 0)

    get @path
    assert_select "td .text-accent", text: "3/?"
  end

  test "a failed backfill reads as failed" do
    track(state: "error", done: 0, total: 0)

    get @path
    assert_select "td .tag.text-err", text: "failed"
  end

  test "the polling frame renders the list alone, without the page around it" do
    track(state: "running")

    get project_niche_channels_path(@project)
    assert_response :success
    assert_select "turbo-frame#niche_channels"
    assert_select "h1", count: 0
  end

  test "tracking a channel links it and queues its collection" do
    assert_enqueued_with(job: Competitors::ChannelBackfillJob) do
      stub_youtube(channel_info) do
        post project_niche_channels_path(@project), params: { reference: "@newbie" }
      end
    end

    assert_redirected_to @path
    channel = CompetitorChannel.find_by(youtube_channel_id: "UC_new")
    assert_equal "@newbie", channel.handle
    assert channel.backfill_queued?
    assert @project.competitor_channels.exists?(channel.id)
    follow_redirect!
    assert_select ".text-ok", text: /Added “Newbie”/
  end

  test "a channel another project already collected is linked without re-collecting" do
    other = Project.create!(name: "Poker")
    known = CompetitorChannel.create!(youtube_channel_id: "UC_new", title: "Newbie", backfill_state: "done")
    other.project_channels.create!(competitor_channel: known)

    assert_no_enqueued_jobs only: Competitors::ChannelBackfillJob do
      stub_youtube(channel_info) { post project_niche_channels_path(@project), params: { reference: "@newbie" } }
    end

    assert @project.competitor_channels.exists?(known.id)
    follow_redirect!
    assert_select ".text-ok", text: /already collected/
  end

  test "an unusable reference is reported without writing anything" do
    assert_no_difference -> { CompetitorChannel.count } do
      stub_youtube(channel_info) { post project_niche_channels_path(@project), params: { reference: "" } }
    end

    assert_redirected_to @path
    follow_redirect!
    assert_select ".text-err"
  end

  test "detaching a channel nobody else tracks says collection stopped" do
    track

    delete project_niche_channel_path(@project, "UC_solo")
    follow_redirect!
    assert_select ".text-ok", text: /collection stopped/
  end

  test "detaching a channel another project still tracks does not stop collection" do
    channel = track
    Project.create!(name: "Poker").project_channels.create!(competitor_channel: channel)

    delete project_niche_channel_path(@project, "UC_solo")
    follow_redirect!
    assert_select ".text-ok", text: /Everything collected is kept\./
    assert channel.reload.active?, "another project still needs it collected"
  end

  test "detaching unlinks the channel but keeps what was collected" do
    channel = track

    assert_no_difference -> { CompetitorChannel.count } do
      delete project_niche_channel_path(@project, "UC_solo")
    end

    assert_redirected_to @path
    assert_empty @project.competitor_channels.reload
    assert_not channel.reload.active?, "an orphaned channel stops being collected"
  end

  test "the channels tab does not pay for the scored dashboard" do
    track

    # Scoring is what the tab must not trigger; a fake that explodes on use proves
    # the branch never reaches it.
    exploding = Object.new
    exploding.define_singleton_method(:call) { raise "the channels tab must not score anything" }
    stubbing(Metrics::NicheDashboard, :new, exploding) do
      get @path
      assert_response :success
    end
  end
end
