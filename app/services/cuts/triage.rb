module Cuts
  # The user's per-source-video triage of a topic: keep as "maybe", "discard", or
  # clear back to "open" (no row). Shared across the source video's cuts; never
  # stores "in" (membership is derived from a cut's items). Ported from the PoC
  # triage repo.
  module Triage
    module_function

    OPEN = "open".freeze

    # Set the opinion. A nil / "open" state clears it (deletes the row).
    def set(source_video, topic, state)
      return clear(source_video, topic) if state.nil? || state.to_s == OPEN

      triage = TopicTriage.find_or_initialize_by(source_video:, topic:)
      triage.update!(state: state.to_s)
      triage
    end

    def clear(source_video, topic)
      TopicTriage.where(source_video:, topic:).delete_all
      nil
    end
  end
end
