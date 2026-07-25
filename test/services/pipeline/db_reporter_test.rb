require "test_helper"

# The DB reporter persists progress for the UI to poll: the PipelineJob row and
# the SourceVideo status. Ported from the PoC `tests/test_progress.py`.
class Pipeline::DbReporterTest < ActiveSupport::TestCase
  def setup
    @project = Project.create!(name: "Niche")
    @sv = @project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    @job = @sv.pipeline_jobs.create!
  end

  test "update writes stage, progress, status and appends to the trail" do
    reporter = Pipeline::DbReporter.new(@job)

    reporter.update(stage: "Audio download", progress: 15, video_status: :downloading)
    reporter.update(stage: "Transcription", progress: 30, video_status: :transcribing)

    @job.reload
    assert_equal "Transcription", @job.stage
    assert_equal 30, @job.progress
    assert_equal "started", @job.status
    assert_equal [ "Audio download", "Transcription" ], @job.stage_history
    assert_equal "transcribing", @sv.reload.status
  end

  test "a stage without a video_status leaves the source video status untouched" do
    @sv.update!(status: "downloading")
    Pipeline::DbReporter.new(@job).update(stage: "Metadata", progress: 5)

    assert_equal "downloading", @sv.reload.status
  end
end
