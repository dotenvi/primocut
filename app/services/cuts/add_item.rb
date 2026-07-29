module Cuts
  # Append a slot to the composition: a topic, or a manual time range.
  #
  # A topic item SNAPSHOTS the topic's range instead of pointing at it, so a later
  # re-analysis that moves or drops the topic cannot silently re-cut a clip that
  # was already decided on.
  class AddItem
    class InvalidRange < StandardError; end

    MESSAGE = "Enter a valid start and end, as 1:05 or in seconds (end after start).".freeze

    def call(cut:, topic_id: nil, start_s: nil, end_s: nil)
      topic = topic_for(cut, topic_id)
      position = Positions.next_for(cut)
      return cut.cut_items.create!(topic:, position:, start_s: topic.start_s, end_s: topic.end_s) if topic

      from, to = seconds(start_s), seconds(end_s)
      raise InvalidRange, MESSAGE unless to > from

      cut.cut_items.create!(position:, start_s: from, end_s: to)
    end

    private

    # Which of the two an item is — a topic or a hand-typed range — is decided
    # here, on the presence of an id, and the topic is looked up rather than handed
    # in already found. Both belong with the rule: the guard that a topic comes
    # from THIS cut's source video has to hold for a job as much as for a browser.
    def topic_for(cut, id)
      return nil if id.blank?

      cut.source_video.topics.find(id)
    end

    # A range is typed the way it is read on screen — "1:05", "0:30", or plain
    # seconds. Refusing the clock form would make the user convert by hand from
    # the very timestamps this room shows them.
    def seconds(value)
      text = value.to_s.strip
      raise InvalidRange, MESSAGE if text.empty?

      parts = text.split(":")
      raise InvalidRange, MESSAGE if parts.size > 3

      parts.reduce(0.0) { |total, part| (total * 60) + Float(part) }
    rescue ArgumentError, TypeError
      raise InvalidRange, MESSAGE
    end
  end
end
