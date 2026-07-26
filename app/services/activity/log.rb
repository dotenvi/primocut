module Activity
  # The full event log, newest first, plus the quota it accounts for. PURE READ.
  #
  # Paginated by descending id rather than by offset: the log only ever grows at
  # the head, so an offset page would shift under the reader between requests and
  # silently skip rows. The cursor is the last id of the page you just read.
  # Ports the PoC `db/events.py::list_activity` + `quota_units_used`.
  class Log
    PER_PAGE = 50

    Result = Struct.new(:rows, :next_before_id, :quota_units, keyword_init: true)

    def initialize(before_id: nil, limit: PER_PAGE)
      @before_id = before_id.presence&.to_i
      @limit = limit
    end

    def call
      events = page.to_a
      Result.new(
        rows: Events::Row.build(events),
        # Only offer the next cursor when a full page came back AND something is
        # actually behind it — so the last page never shows a link to nothing.
        next_before_id: (events.last.id if events.size == @limit && more_after?(events.last)),
        quota_units: QuotaUsed.new.call
      )
    end

    private

    def page
      scope = Event.order(id: :desc).limit(@limit)
      @before_id ? scope.where(id: ...@before_id) : scope
    end

    def more_after?(last) = Event.where(id: ...last.id).exists?
  end
end
