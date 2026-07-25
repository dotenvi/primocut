# Extract a cut's candidate thumbnail frames in the background — FFmpeg only, no
# LLM. Thin: delegate to Cuts::PackagingService.
class ExtractCutFramesJob < ApplicationJob
  queue_as :default

  def perform(cut_id, item_ids: nil, regenerate: false, service: Cuts::PackagingService.new)
    cut = Cut.find(cut_id)
    service.extract_frames(cut, item_ids:, regenerate:)
  end
end
