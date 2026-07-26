module Competitors
  # Thin ActiveJob wrapper around [[Competitors::VideoAnalysis]]: analyzes a batch of
  # videos for one `kind`, with per-video isolation (a single-video analyze is just a
  # one-element list). Runs ONLY from an explicit user action (a video-detail button,
  # a project batch, or a CLI) — never from the snapshot cycle, because this is the
  # paid, opt-in pass. Ported from the PoC `worker/enrich_jobs.py`.
  class VideoAnalysisJob < ApplicationJob
    queue_as :default

    def perform(youtube_video_ids, kind = "title", regenerate: false)
      analyzer = VideoAnalysis.new
      Array(youtube_video_ids).each { |youtube_video_id| analyzer.call(youtube_video_id, kind:, regenerate:) }
    end
  end
end
