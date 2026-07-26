module Events
  # One row of the event log: an event plus the subjects it soft-references.
  # Shared by every screen that renders events — the Radar feed, its ops alerts
  # and the Activity log — exactly as the PoC serves all three from one
  # `_serialise`.
  #
  # Events carry nullable bigint soft-refs (no FK, no `belongs_to`) so a recorded
  # fact outlives the deletion of its subject — which means the feed has to
  # resolve titles, thumbnails and project badges itself. `build` does that in a
  # fixed number of queries for a whole page, never per row (ports the PoC
  # `api/events.py::_serialise`).
  Row = Struct.new(:event, :video, :channel, :source_video, :projects, keyword_init: true) do
    def id = event.id
    def event_type = event.event_type
    def payload = event.payload
    def occurred_at = event.occurred_at
    def seen? = event.seen_at.present?

    # A card names the thing that happened: the competitor video (niche) or the
    # source video (ops), falling back to the raw id and then to the event type.
    def title
      video&.title.presence || source_video&.title.presence ||
        video&.youtube_video_id.presence || event_type.humanize
    end

    def channel_title = channel&.title.presence
    def thumbnail_url = video&.thumbnail_url.presence
    def views = payload["views"]

    # The video format this event refers to (which channel-spread strip to pull).
    # Defaults to long-form when the payload predates the `is_short` field.
    def video_format = payload["is_short"] ? "short" : "long"

    # A card opens the video inside a project that tracks its channel: the
    # filtered project when it tracks it, else the first badge.
    def project_for(current = nil)
      return current if current && projects.any? { |p| p.id == current.id }

      projects.first
    end

    def linkable?(current = nil) = video.present? && channel.present? && project_for(current).present?

    # Batch-resolve a page of events into rows. Five bounded queries regardless of
    # how many events the page holds.
    def self.build(events)
      events = events.to_a
      return [] if events.empty?

      videos = CompetitorVideo.where(id: events.filter_map(&:competitor_video_id).uniq).index_by(&:id)
      channels = CompetitorChannel.where(id: events.filter_map(&:competitor_channel_id).uniq).index_by(&:id)
      sources = SourceVideo.where(id: events.filter_map(&:source_video_id).uniq).index_by(&:id)
      badges = project_badges(channels.keys)

      events.map do |event|
        new(
          event: event,
          video: videos[event.competitor_video_id],
          channel: channels[event.competitor_channel_id],
          source_video: sources[event.source_video_id],
          projects: badges.fetch(event.competitor_channel_id, [])
        )
      end
    end

    # Map each channel to the projects that track it (its Radar badges). One query
    # for the whole page: a channel in two projects yields one row with two
    # badges, never a duplicated row.
    def self.project_badges(channel_ids)
      return {} if channel_ids.empty?

      ProjectChannel.where(competitor_channel_id: channel_ids)
                    .includes(:project)
                    .order("projects.name")
                    .references(:project)
                    .group_by(&:competitor_channel_id)
                    .transform_values { |links| links.map(&:project) }
    end
  end
end
