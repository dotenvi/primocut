module Enrichment
  # Thin ActiveJob wrapper around [[Enrichment::VideoEnricher]]: enriches a batch of
  # videos for one `kind`, with per-video isolation (a single-video enrich is just a
  # one-element list). Runs ONLY from an explicit user action (a video-detail button,
  # a project batch, or a CLI) — never from the snapshot cycle, because this is the
  # paid, opt-in pass. Ported from the PoC `worker/enrich_jobs.py`.
  class EnrichJob < ApplicationJob
    queue_as :default

    def perform(youtube_video_ids, kind = "title")
      enricher = VideoEnricher.new
      Array(youtube_video_ids).each { |youtube_video_id| enricher.call(youtube_video_id, kind:) }
    end
  end
end
