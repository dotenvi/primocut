# Match the niche's audience requests to a source video's topics in the background,
# cached per source video. Thin: delegate to Cuts::PackagingService.
class MatchAudienceJob < ApplicationJob
  queue_as :default

  def perform(source_video_id, regenerate: false, service: Cuts::PackagingService.new)
    source_video = SourceVideo.find(source_video_id)
    service.match_audience(source_video, regenerate:)
  end
end
