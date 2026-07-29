module Cuts
  # The user's per-source-video triage of a topic: keep as "maybe", "discard", or
  # clear back to "open" (no row). Shared across the source video's cuts; never
  # stores "in" (membership is derived from a cut's items). Ported from the PoC
  # triage repo.
  class Triage
    OPEN = "open".freeze

    # Record the opinion. A nil / "open" state clears it (deletes the row). The
    # topic is resolved here, off the source video, so an id belonging to another
    # video cannot be triaged onto this one.
    def call(source_video:, topic_id:, state:)
      topic = source_video.topics.find(topic_id)
      return clear(source_video, topic) if state.nil? || state.to_s == OPEN

      triage = TopicTriage.find_or_initialize_by(source_video:, topic:)
      triage.update!(state: state.to_s)
      triage
    end

    private

    def clear(source_video, topic)
      TopicTriage.where(source_video:, topic:).delete_all
      nil
    end
  end
end
