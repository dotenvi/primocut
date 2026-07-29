require "test_helper"

# The render telemetry: how far, how fast, how much longer — all measured off the
# clips' own timestamps, since items are rendered one at a time in order.
class Cuts::RenderProgressTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Chess")
    @video = @project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    @cut = @video.cuts.create!
    @now = Time.utc(2026, 7, 26, 14, 0, 0)
  end

  # start/end give the media seconds; created/updated give the wall seconds.
  def item(position:, media_s:, state: nil, wall_s: 0, bytes: 0, error: "")
    it = @cut.cut_items.create!(position:, start_s: position * 1000, end_s: (position * 1000) + media_s)
    if state
      it.create_clip!(cut_id: @cut.id, source_video_id: @video.id, state:, error:, size_bytes: bytes,
                      created_at: @now - wall_s, updated_at: @now)
    end
    it
  end

  def progress
    items = @cut.cut_items.reorder(:position).includes(:clip).to_a
    Cuts::RenderProgress.new.call(items, now: @now)
  end

  test "an untouched cut has nothing to report" do
    item(position: 0, media_s: 30)
    r = progress
    assert_equal 0, r.percent
    refute r.working?
    assert_nil r.started_at
    assert_nil r.throughput
    assert_nil r.eta_s
  end

  test "progress is measured in MEDIA seconds, not in item count" do
    # One long item done, one short one pending: 5/6 of the work, but half the items.
    item(position: 0, media_s: 300, state: "done", wall_s: 300)
    item(position: 1, media_s: 60)

    r = progress
    assert_equal 83, r.percent
    assert_equal 1, r.done_count
    assert_equal 2, r.total_count
    assert_in_delta 300.0, r.done_media_s
    assert_in_delta 360.0, r.total_media_s
  end

  test "throughput is wall time per second of media, over the finished items only" do
    item(position: 0, media_s: 100, state: "done", wall_s: 138)
    item(position: 1, media_s: 200, state: "cutting", wall_s: 50) # in flight: excluded

    assert_in_delta 1.38, progress.throughput, 0.001
  end

  test "a finished item reports its own cost, an in-flight one its elapsed time" do
    item(position: 0, media_s: 100, state: "done", wall_s: 138, bytes: 70_000_000)
    item(position: 1, media_s: 200, state: "downloading_section", wall_s: 50)

    done, working = progress.items
    assert_in_delta 138.0, done.wall_s
    assert_in_delta 1.38, done.ratio, 0.001
    assert_in_delta 5.6, done.bitrate / 1_000_000, 0.1
    assert done.done

    assert_in_delta 50.0, working.wall_s
    assert working.working
    assert_nil working.bitrate, "an unfinished clip has no bitrate to report"
  end

  test "the item in flight is the one the screen points at" do
    item(position: 0, media_s: 100, state: "done", wall_s: 100)
    item(position: 1, media_s: 100, state: "cutting", wall_s: 10)
    item(position: 2, media_s: 100)

    assert progress.working?
    assert_equal 1, progress.working_item.cut_item.position
  end

  # The estimate must discount what the running item already spent, or it would
  # keep quoting the same "time left" while the item burns through it.
  test "the estimate charges the remaining media at the measured rate, less what is spent" do
    item(position: 0, media_s: 100, state: "done", wall_s: 100)   # rate = 1.0
    item(position: 1, media_s: 200, state: "cutting", wall_s: 60) # 200s of media left, 60 spent

    assert_equal 140, progress.eta_s
  end

  test "there is no estimate before anything has finished" do
    item(position: 0, media_s: 100, state: "cutting", wall_s: 10)
    assert_nil progress.eta_s
  end

  test "a settled render offers no estimate, since nothing is left to wait for" do
    item(position: 0, media_s: 100, state: "done", wall_s: 100)
    r = progress
    refute r.working?
    assert_nil r.eta_s
    assert_equal 100, r.percent
  end

  test "a failed clip is counted and carries its reason" do
    item(position: 0, media_s: 100, state: "error", wall_s: 20, error: "ffmpeg exited 1")
    r = progress
    assert_equal 1, r.failed_count
    assert_equal 0, r.done_count
    assert_equal "ffmpeg exited 1", r.items.first.error
  end

  test "only finished clips count toward the bytes on disk" do
    item(position: 0, media_s: 100, state: "done", wall_s: 100, bytes: 1_000)
    item(position: 1, media_s: 100, state: "cutting", wall_s: 10, bytes: 999_999)

    assert_equal 1_000, progress.bytes
  end

  test "the run's wall clock spans the first item's turn to now while working" do
    item(position: 0, media_s: 100, state: "done", wall_s: 300)
    item(position: 1, media_s: 100, state: "cutting", wall_s: 60)

    # The earliest clip started 300s ago and something is still running.
    assert_in_delta 300.0, progress.elapsed_s
  end
end
