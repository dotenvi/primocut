class Event < ApplicationRecord
  # Append-only fact log. Subjects are nullable bigint soft-refs (no belongs_to,
  # no FK): a recorded fact must outlive the deletion of any subject.
  enum :category, { niche: "niche", ops: "ops" }, prefix: :category
  enum :severity, { info: "info", error: "error" }, prefix: :severity

  # `event_type` is an open taxonomy (outlier_crossed, packaging_changed,
  # pipeline_failed, cycle_done, …) — plain string, grows with features.
  validates :event_type, :occurred_at, presence: true
end
