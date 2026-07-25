module Pipeline
  # The reporter used off the job path (the CLI): logs only, persists nothing.
  # Ported from the PoC `progress.py::LogReporter`.
  class LogReporter
    def update(stage:, progress:, video_status: nil)
      Rails.logger.debug("progress: #{stage} (#{progress}%) status=#{video_status}")
    end
  end
end
