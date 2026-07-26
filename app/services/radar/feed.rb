module Radar
  # The cross-project niche feed: newest first, split into unseen ("New") and
  # seen ("Earlier"). PURE READ.
  #
  # Niche events carry a channel, never a project — a channel can belong to
  # several projects, so filtering by project resolves that project's channels
  # first (ports the PoC `db/events.py::list_niche_events`). A project that
  # tracks no channel yields an empty feed rather than the whole one.
  class Feed
    LIMIT = 100

    Result = Struct.new(:unseen, :seen, keyword_init: true)

    def initialize(project: nil, limit: LIMIT)
      @project = project
      @limit = limit
    end

    def call
      unseen, seen = Row.build(events).partition { |row| !row.seen? }
      Result.new(unseen: unseen, seen: seen)
    end

    private

    def events
      scope = Event.category_niche
      if @project
        channel_ids = @project.project_channels.pluck(:competitor_channel_id)
        return Event.none if channel_ids.empty?

        scope = scope.where(competitor_channel_id: channel_ids)
      end
      scope.order(occurred_at: :desc, id: :desc).limit(@limit)
    end
  end
end
