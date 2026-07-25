# An opt-in AI packaging artifact for one cut item (the PoC `CutPackagingRow`),
# cached per (cut_item, kind). `title`/`thumb_brief` are LLM passes; `frame_ranking`
# is the opt-in vision pass over the deterministically extracted frames. Paid for
# once by `content_hash`; `state`/`error` let the UI poll an in-flight generation.
class CutPackaging < ApplicationRecord
  belongs_to :cut_item

  KINDS = %w[title thumb_brief frame_ranking].freeze

  enum :state,
       { running: "running", done: "done", error: "error" },
       prefix: :state, default: "done"

  # `kind` is a closed taxonomy but kept a plain string (mirrors VideoEnrichment).
  validates :kind, presence: true, inclusion: { in: KINDS },
            uniqueness: { scope: :cut_item_id }
end
