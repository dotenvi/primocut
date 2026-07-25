# The cached audience -> topic match for a source video (the PoC
# `LiveAudienceMatchRow`, renamed off "live"). One row per source video: the
# semantic match of the niche's synthesised audience requests to the source
# video's topics. `payload` maps topic_id -> the requests it delivers;
# `content_hash` folds the topics AND the request set, recomputing only on change.
class AudienceMatch < ApplicationRecord
  belongs_to :source_video

  enum :state,
       { running: "running", done: "done", error: "error" },
       prefix: :state, default: "done"
end
