require "test_helper"
require Rails.root.join("lib/primocut/cli")

# The Thor CLI is a thin dispatcher over already-tested services. These cover the
# offline paths: the metrics JSON dump (parity workflow) and the argument/lookup
# error handling. The pipeline/snapshot/export heavy paths are covered by their
# own service and job tests — here we only assert the CLI's record resolution and
# failure surfacing, which need no network or GPU.
class Primocut::CliTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Chess")
    @channel = CompetitorChannel.create!(youtube_channel_id: "UC_solo", title: "Solo", handle: "@solo")
    @project.project_channels.create!(competitor_channel: @channel)
    @channel.channel_snapshots.create!(captured_at: Time.current, subscribers: 12_345)
    @video = @channel.competitor_videos.create!(youtube_video_id: "v1", title: "Question?", published_at: 60.days.ago)
    @video.video_snapshots.create!(captured_at: 1.hour.ago, views: 1000)
  end

  test "metrics --project dumps the niche dashboard as JSON" do
    out, = capture_io { Primocut::Cli.start([ "metrics", "--project", @project.id.to_s ]) }
    data = JSON.parse(out)
    assert_equal "Chess", data.dig("project", "name")
    assert data.key?("outliers")
  end

  test "metrics --channel dumps the channel dashboard as JSON" do
    out, = capture_io { Primocut::Cli.start([ "metrics", "--channel", "UC_solo" ]) }
    data = JSON.parse(out)
    assert data.key?("channel")
    assert data.key?("baselines")
  end

  test "metrics --channel --video dumps the video report as JSON" do
    out, = capture_io { Primocut::Cli.start([ "metrics", "--channel", "UC_solo", "--video", "v1" ]) }
    data = JSON.parse(out)
    assert data.key?("video")
    assert data.key?("snapshots")
  end

  test "metrics with no target aborts with guidance" do
    out, = capture_io do
      assert_raises(SystemExit) { Primocut::Cli.start([ "metrics" ]) }
    end
    assert_match(/Pass --project/, out)
  end

  test "metrics with an unknown project aborts with Not found" do
    out, = capture_io do
      assert_raises(SystemExit) { Primocut::Cli.start([ "metrics", "--project", "999999" ]) }
    end
    assert_match(/Not found/, out)
  end

  test "pipeline with an unknown project aborts before any network call" do
    out, = capture_io do
      assert_raises(SystemExit) { Primocut::Cli.start([ "pipeline", "https://youtu.be/abc", "--project", "999999" ]) }
    end
    assert_match(/not found/i, out)
  end

  test "export with an unknown cut aborts with Not found" do
    out, = capture_io do
      assert_raises(SystemExit) { Primocut::Cli.start([ "export", "--cut", "999999" ]) }
    end
    assert_match(/not found/i, out)
  end
end
