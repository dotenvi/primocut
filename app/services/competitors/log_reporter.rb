module Competitors
  # The snapshot cycle's default reporter: logs only, persists nothing. It is what
  # keeps [[Competitors::SnapshotCycleJob]] unchanged by the CLI's progress display
  # — a background job wants the Rails log, not a terminal. Mirrors
  # [[Pipeline::LogReporter]], the same seam one layer over.
  class LogReporter
    def update(stage:, progress:, detail: nil, **)
      Rails.logger.debug("snapshot: #{stage} (#{progress}%) #{detail}")
    end

    def warn(message) = Rails.logger.warn("snapshot: #{message}")

    def close = nil
  end
end
