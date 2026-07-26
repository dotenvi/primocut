module Activity
  # YouTube API quota accounted across the cycle events, optionally since a given
  # moment. PURE READ. Ports the PoC `db/events.py::quota_units_used`.
  #
  # Summed in Ruby, not in SQL: the units live inside the payload, which SQL would
  # need a jsonb cast to reach, and cycle events are a few per day. The `since`
  # bound is what keeps the sidebar's per-request read small as the log grows.
  class QuotaUsed
    CYCLE_DONE = "cycle_done".freeze

    def initialize(since: nil)
      @since = since
    end

    def call
      scope = Event.where(event_type: CYCLE_DONE)
      scope = scope.where(occurred_at: @since..) if @since
      scope.pluck(:payload).sum { |payload| payload["quota_units"].to_i }
    end
  end
end
