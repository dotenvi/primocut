# The state of a cut's latest export (the PoC `ExportRow`), one row per cut. An
# export packages the cut's rendered clips into a deliverable bundle on disk; this
# row is what the UI polls to learn when the zip is ready.
class Export < ApplicationRecord
  belongs_to :cut

  enum :state,
       { queued: "queued", packaging: "packaging", done: "done", error: "error" },
       prefix: :state, default: "queued"
end
