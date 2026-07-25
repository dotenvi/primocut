# Rank a cut's extracted frames against their briefs in the background (opt-in
# vision pass). Thin: delegate to Cuts::PackagingService.
class RankCutFramesJob < ApplicationJob
  queue_as :default

  def perform(cut_id, item_ids: nil, service: Cuts::PackagingService.new)
    cut = Cut.find(cut_id)
    service.rank_frames(cut, item_ids:)
  end
end
