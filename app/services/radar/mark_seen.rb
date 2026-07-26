module Radar
  # Clear the feed: every unseen niche event up to `now` is marked seen. Returns
  # how many rows were newly marked.
  #
  # Ops events are never touched — they close by being resolved, not by being
  # looked at. One UPDATE, no rows loaded: the feed is cleared in bulk, and the
  # `occurred_at` bound keeps an event emitted mid-request out of the sweep, so
  # nothing is marked seen before it was ever on screen.
  class MarkSeen
    def initialize(now: Time.current)
      @now = now
    end

    def call
      Event.category_niche.where(seen_at: nil).where(occurred_at: ..@now)
           .update_all(seen_at: @now)
    end
  end
end
