require "tmpdir"

# Runs the whole pipeline for one source video. Thin: create the progress row,
# call the stage core with the DB reporter, and translate an essential failure
# into a persisted error state plus an ops alert for the Radar.
#
# The `gpu` queue IS the GPU lock (threads: 1) — one pipeline, hence one
# transcription, at a time. What the PoC did with a Redis lock (gpu.py) is now
# queue configuration, so no lock code lives here.
class SourceVideoPipelineJob < ApplicationJob
  queue_as :gpu

  def perform(source_video_id, runner: Pipeline::Runner.new)
    source_video = SourceVideo.find(source_video_id)
    job = source_video.pipeline_jobs.create!(status: "started")
    reporter = Pipeline::DbReporter.new(job)

    begin
      Dir.mktmpdir("primocut-") do |audio_dir|
        result = runner.call(source_video, reporter: reporter, audio_dir: audio_dir)
        job.update!(status: "finished", stage: "Done", progress: 100, warnings: result.warnings)
      end
    rescue Pipeline::Error => e
      record_failure(source_video, job, e)
      raise
    end
  end

  private

  def record_failure(source_video, job, error)
    job.update!(status: "failed", stage_history: job.stage_history + [ "__end__" ], error: error.message)
    source_video.update!(status: "error")
    record_ops_event(source_video, job, error)
  end

  # Isolated: a log-write failure must not mask the real pipeline error.
  def record_ops_event(source_video, job, error)
    Event.create!(
      category: "ops", event_type: "pipeline_failed", severity: "error",
      project_id: source_video.project_id, source_video_id: source_video.id,
      occurred_at: Time.current, payload: { "job_id" => job.id, "error" => error.message }
    )
  rescue StandardError => e
    Rails.logger.error("pipeline_failed log failed: #{e.message}")
  end
end
