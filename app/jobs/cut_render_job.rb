# Render a cut's clips in the background. Thin: delegate to Cuts::Render, which
# owns the per-item isolation and the pay-once cache. NOT on the `gpu` queue —
# rendering runs alongside triage, and (unlike transcription) does not serialize
# on the GPU; only the optional align inference would, and it takes the lock itself.
class CutRenderJob < ApplicationJob
  queue_as :default

  def perform(cut_id, item_ids: nil, regenerate: false, fast_copy: false, service: Cuts::Render.new)
    cut = Cut.find(cut_id)
    service.call(cut, item_ids:, regenerate:, fast_copy:)
  ensure
    # The Cut Room flips the cut to "rendering" before enqueuing so its frame polls;
    # settle it back when the pass finishes (only if we still own that state).
    cut&.update!(status: "rendered") if cut&.status == "rendering"
  end
end
