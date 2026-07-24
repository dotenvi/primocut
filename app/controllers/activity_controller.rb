class ActivityController < ApplicationController
  # The full activity log across projects. Quota accounting and the operational
  # events that fill this log arrive with collection (Phase 3); until then the log
  # is empty and the quota is unknown.
  def show
    @events = Event.order(occurred_at: :desc).limit(100)
    @quota = nil # YouTube API quota tracking lands in Phase 3
  end
end
