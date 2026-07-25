# Progress + outcome of one pipeline run for a source video (the PoC `jobs` row).
# `stage_history` is the append-only trail of stages the run passed through;
# `warnings` are the degradation notes the run accumulated.
class PipelineJob < ApplicationRecord
  belongs_to :source_video

  enum :status, {
    queued: "queued",
    started: "started",
    finished: "finished",
    failed: "failed"
  }, default: "queued"
end
