# A rendered clip: one MP4 deliverable per cut item (the PoC `ClipRow`), produced
# by the section download + FFmpeg re-encode. 1:1 with its cut item. `params_hash`
# is the pay-once cache key over (range + padding + encode profile); the same item
# re-rendered with the same parameters is skipped unless regeneration is forced.
# `encode_profile` is what was REQUESTED; `encoder_used` is what actually produced
# the file (records the libx264 fallback when NVENC was requested but unavailable).
class Clip < ApplicationRecord
  belongs_to :cut_item

  enum :state,
       {
         queued: "queued",
         downloading_section: "downloading_section",
         aligning: "aligning",
         cutting: "cutting",
         done: "done",
         error: "error"
       },
       prefix: :state, default: "queued"
end
