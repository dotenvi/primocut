require "test_helper"

# The pipeline job: thin, but it owns the outcome bookkeeping (finished vs a
# persisted error state + a Radar ops alert). Driven with the real Runner over
# fake adapters — no network, no GPU. Ported from the PoC `tests/test_jobs.py`.
class SourceVideoPipelineJobTest < ActiveSupport::TestCase
  class FakeYtdlp
    def initialize(fail_download: false)
      @fail_download = fail_download
    end

    def fetch_metadata(_url)
      Adapters::Ytdlp::Metadata.new(youtube_id: "abcdefghijk", url: "https://y/1", title: "T", channel: "C", duration_s: 100)
    end

    def download_audio(_url, dir, video_id:)
      raise Adapters::Ytdlp::Error, "extractor broke" if @fail_download

      "#{dir}/#{video_id}.wav"
    end
  end

  class FakeEngine
    def degradation_warnings = []

    def transcribe(_audio_path, video_id:)
      Pipeline::Transcript.new(
        youtube_id: video_id, language: "pt", model: "faster-whisper:m",
        segments: [ Pipeline::Segment.new(index: 0, start: 0.0, end: 10.0, text: "oi") ]
      )
    end
  end

  class FakeChat
    def download(_url) = nil
  end

  def setup
    @project = Project.create!(name: "Niche")
    @sv = @project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
  end

  def runner(fail_download: false)
    Pipeline::Runner.new(ytdlp: FakeYtdlp.new(fail_download: fail_download), engine: FakeEngine.new, chat_downloader: FakeChat.new)
  end

  test "a successful run finishes the job and persists the artifacts" do
    SourceVideoPipelineJob.new.perform(@sv.id, runner: runner)

    @sv.reload
    assert @sv.done?
    assert @sv.transcript.present?
    job = @sv.pipeline_jobs.last
    assert_equal "finished", job.status
    assert_equal 100, job.progress
  end

  test "an essential failure records the error state and a Radar ops alert" do
    assert_raises(Pipeline::Error) do
      SourceVideoPipelineJob.new.perform(@sv.id, runner: runner(fail_download: true))
    end

    @sv.reload
    assert @sv.error?
    job = @sv.pipeline_jobs.last
    assert_equal "failed", job.status
    assert_includes job.stage_history, "__end__"
    assert_match "extractor broke", job.error

    event = Event.find_by(event_type: "pipeline_failed")
    assert_equal "ops", event.category
    assert_equal "error", event.severity
    assert_equal @project.id, event.project_id
    assert_equal @sv.id, event.source_video_id
    assert_equal job.id, event.payload["job_id"]
  end

  test "runs on the gpu queue — the queue is the GPU lock" do
    assert_equal "gpu", SourceVideoPipelineJob.new.queue_name
  end
end
