# Export a cut into its deliverable bundle in the background. Thin: delegate to
# Cuts::Export, which owns the plan, the file IO and the export row's state.
class CutExportJob < ApplicationJob
  queue_as :default

  def perform(cut_id, render_missing: false, skip_master: false, upscale: false,
              make_zip: true, service: Cuts::Export.new)
    cut = Cut.find(cut_id)
    service.call(cut, render_missing:, skip_master:, upscale:, make_zip:)
  end
end
