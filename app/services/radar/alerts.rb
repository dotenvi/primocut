module Radar
  # Open operational failures: `category='ops' AND resolved_at IS NULL`. These sit
  # above the niche feed as the "Needs you" band. Ops events are never marked
  # seen — they close by being resolved. PURE READ.
  class Alerts
    LIMIT = 20

    def initialize(limit: LIMIT)
      @limit = limit
    end

    def call
      Row.build(
        Event.category_ops.where(resolved_at: nil)
             .order(occurred_at: :desc, id: :desc).limit(@limit)
      )
    end
  end
end
