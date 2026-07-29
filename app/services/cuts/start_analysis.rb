module Cuts
  # Regenerate a source video's topics with the LLM, in the background.
  #
  # The video is flipped to `analyzing` before the job is queued, not by the job:
  # that flip is what makes the screen start polling, and a job that has not been
  # picked up yet would leave the room looking idle while work is pending.
  class StartAnalysis
    def call(source_video:)
      source_video.update!(status: "analyzing")
      AnalyzeTopicsJob.perform_later(source_video.id)
      source_video
    end
  end
end
