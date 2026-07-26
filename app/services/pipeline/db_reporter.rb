module Pipeline
  # The reporter that persists progress for the UI to read: it updates the
  # PipelineJob (stage/progress/status + the append-only stage trail) and the
  # SourceVideo's status. The stage core stays identical between the job and the
  # CLI — only this collaborator changes (docs §2.3). Ported from the PoC
  # `progress.py::DbReporter`.
  class DbReporter
    def initialize(pipeline_job)
      @job = pipeline_job
      @source_video = pipeline_job.source_video
    end

    # Each transition is recorded with the moment it happened. The timestamp is
    # not decoration: it is the only source of per-step duration, and a trail of
    # bare stage names cannot say how long anything took. Same shape the PoC
    # wrote, so imported runs and new ones read identically.
    def update(stage:, progress:, video_status: nil, at: Time.current)
      @job.update!(
        stage: stage,
        progress: progress,
        status: "started",
        stage_history: @job.stage_history + [ { "stage" => stage, "at" => at.iso8601 } ]
      )
      @source_video.update!(status: video_status) if video_status
    end
  end
end
