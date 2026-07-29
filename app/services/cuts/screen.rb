module Cuts
  # Everything the Cut Room renders around one source video's active cut: the
  # topics with the opinion recorded about each, which of them are already in the
  # composition, and the packaging produced so far. PURE READ.
  class Screen
    Result = Struct.new(:source_video, :cut, :topics, :triage, :composed,
                        :packaging, :audience, :transcript_segments, :items, :master, :render,
                        keyword_init: true) do
      def triage_for(topic) = triage[topic.id]
      def composed?(topic) = composed.key?(topic.id)

      # The item a topic became — what the bench needs to offer taking it back out
      # through the same control that put it in.
      def item_for(topic) = composed[topic.id]
      def packaging_for(item) = packaging.fetch(item.id, {})
      def duration = items.sum { |item| item.end_s - item.start_s }

      def rendered_items = items.select { |item| item.clip&.state_done? }

      # Playback is the concatenated master, so it needs the file to exist — which in
      # turn needs EVERY item rendered, since a master missing an item would silently
      # misrepresent the composition.
      def playable? = master.present?

      # Where each item starts inside the master: the clips are concatenated in order,
      # so an item's offset is the durations before it. This is what makes the segment
      # strip a seek bar over one continuous file.
      def offsets
        items.each_with_object([]) { |item, acc| acc << (acc.last || 0.0) + (item.end_s - item.start_s) }
             .unshift(0.0).first(items.size)
      end
    end

    def initialize(source_video, cut)
      @source_video = source_video
      @cut = cut
    end

    def call
      items = @cut.cut_items.reorder(:position).includes(:clip, :topic).to_a
      Result.new(
        source_video: @source_video, cut: @cut,
        topics: @source_video.topics.ordered.to_a,
        triage: @source_video.topic_triages.index_by(&:topic_id),
        # Read off the items already loaded above rather than queried again: a
        # manual range has no topic, so it simply never lands in the map.
        composed: items.select(&:topic_id).index_by(&:topic_id),
        packaging: packaging_by_item,
        audience: @source_video.audience_match,
        transcript_segments: Array(@source_video.transcript&.segments),
        items: items,
        master: Master.new.path_for(@cut),
        # Measured off the items already loaded above — no extra queries on a frame
        # that re-reads itself every couple of seconds.
        render: RenderProgress.new.call(items)
      )
    end

    private

    # {cut_item_id => {kind => CutPackaging}} — one query for the whole cut, since
    # this is re-read every couple of seconds while a pass runs.
    def packaging_by_item
      CutPackaging.where(cut_id: @cut.id).group_by(&:cut_item_id)
                  .transform_values { |rows| rows.index_by(&:kind) }
    end
  end
end
