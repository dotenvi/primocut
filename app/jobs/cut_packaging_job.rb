# Generate a cut's AI packaging (title/thumb_brief) in the background. Thin:
# delegate to Cuts::PackagingService, which owns the per-item isolation and the
# content-hash cache. Network-bound (LLM), so the default queue.
class CutPackagingJob < ApplicationJob
  queue_as :default

  def perform(cut_id, kind:, item_ids: nil, regenerate: false, service: Cuts::PackagingService.new)
    cut = Cut.find(cut_id)
    service.generate(cut, kind:, item_ids:, regenerate:)
  end
end
