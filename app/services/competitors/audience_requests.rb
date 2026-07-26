module Competitors
  # Project-level aggregation of what the audience asked for, merged across the
  # comment syntheses of a project's videos. A pure read: it loads the `done`
  # `comment_synthesis` payloads for the project's videos and folds them with
  # [[Competitors::CommentSynthesis]].aggregate_requests, so spelling variants collapse and
  # the ranking is plain counting. Ported from the PoC `service.project_dashboard`
  # (`audience_requests`).
  class AudienceRequests
    def initialize(project)
      @project = project
    end

    def call
      video_ids = CompetitorVideo
        .joins(competitor_channel: :project_channels)
        .where(project_channels: { project_id: @project.id })
        .distinct.pluck(:id)

      items = VideoEnrichment
        .where(competitor_video_id: video_ids, kind: CommentSynthesis::KIND, state: "done")
        .pluck(:competitor_video_id, :payload)

      CommentSynthesis.aggregate_requests(items)
    end
  end
end
