module Cuts
  # Build the deliverable bundle in the background. The export row is seeded to
  # `queued` before the job is enqueued so the frame has something to poll on from
  # the very first render.
  class StartExport
    def call(cut:, skip_master: false, upscale: false)
      export = cut.export || cut.create_export!(source_video_id: cut.source_video_id)
      export.update!(state: "queued", error: "")
      CutExportJob.perform_later(cut.id, skip_master:, upscale:)
      export
    end
  end
end
