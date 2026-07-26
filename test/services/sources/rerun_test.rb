require "test_helper"

# Re-running a source video. Refused while it is in flight: two runs for the same
# video would fight for the single GPU slot and overwrite each other's progress.
class Sources::RerunTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup { @project = Project.create!(name: "Chess") }

  def video(status:) = @project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1", status: status)

  test "queues a failed video again" do
    failed = video(status: "error")

    assert_enqueued_with(job: SourceVideoPipelineJob) do
      Sources::Rerun.new.call(project: @project, id: failed.id)
    end
    assert failed.reload.queued?
  end

  test "queues a finished video again" do
    done = video(status: "done")

    Sources::Rerun.new.call(project: @project, id: done.id)

    assert done.reload.queued?
  end

  test "refuses a video that is still running" do
    SourceVideo::ACTIVE_STATUSES.each do |status|
      running = video(status: status)

      assert_no_enqueued_jobs only: SourceVideoPipelineJob do
        assert_raises(Sources::Rerun::StillRunning) { Sources::Rerun.new.call(project: @project, id: running.id) }
      end
      running.destroy!
    end
  end

  test "another project's video does not exist here" do
    other = Project.create!(name: "Poker")
    theirs = other.source_videos.create!(youtube_id: "ccccccccccc", url: "https://y/c", status: "error")

    assert_raises(ActiveRecord::RecordNotFound) { Sources::Rerun.new.call(project: @project, id: theirs.id) }
  end
end
