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

  # The pay-once cache key over the render parameters: range + padding + encode
  # profile + the boundary-refinement tolerance (a new tolerance can move the exact
  # cut points, so it must re-render; 0 when refinement is off). Whether NVENC or
  # alignment were actually available at runtime is environmental and stays out.
  def self.params_hash(start_s, end_s, padding_s, profile, tolerance_s = 0.0)
    raw = format("%.3f|%.3f|%.3f|%s|%.3f", start_s, end_s, padding_s, profile, tolerance_s)
    Digest::SHA1.hexdigest(raw)
  end
end
