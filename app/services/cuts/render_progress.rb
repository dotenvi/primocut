module Cuts
  # What a render is doing right now, measured — not guessed. Built from the cut's
  # items and their clips, which the screen has already loaded, so it adds no
  # queries to a frame that re-reads itself every couple of seconds.
  #
  # A render costs real minutes of GPU and bandwidth, and the useful question while
  # it runs is never "is it working?" but "how far, how fast, how much longer". All
  # three come from the clips' own timestamps: a clip's `created_at` is when its
  # turn started and `updated_at` is when it settled, because items are rendered
  # ONE AT A TIME, in order.
  class RenderProgress
    WORKING_STATES = %w[queued downloading_section aligning cutting].freeze

    # Per item. `wall` is seconds of real time the item cost (or has cost so far);
    # `ratio` is that against the media it produced — the honest unit of render
    # cost, since a 20s item and a 5min item are not comparable in seconds.
    Item = Struct.new(:cut_item, :clip, :media_s, :wall_s, :bytes, :done, :working, :failed,
                      keyword_init: true) do
      def ratio = media_s.positive? && wall_s.to_f.positive? ? wall_s / media_s : nil
      # Bits per second of the produced file — constant-quality encoding makes this
      # vary with the scene, so it is per item and never averaged into a promise.
      def bitrate = done && media_s.positive? ? (bytes * 8.0) / media_s : nil
      def error = clip&.error.presence
    end

    Result = Struct.new(:items, :total_media_s, :done_media_s, :total_count, :done_count,
                        :failed_count, :bytes, :elapsed_s, :started_at, keyword_init: true) do
      def any? = total_count.positive?
      def working? = items.any?(&:working)
      def working_item = items.find(&:working)
      def percent = total_media_s.positive? ? (done_media_s / total_media_s * 100).round : 0
      def remaining_media_s = [ total_media_s - done_media_s, 0 ].max

      # Seconds of real time spent per second of media produced, over the items that
      # actually finished. nil until one has — there is nothing to measure before.
      def throughput
        return nil if done_media_s <= 0

        finished_wall = items.select(&:done).sum { |i| i.wall_s.to_f }
        finished_wall.positive? ? finished_wall / done_media_s : nil
      end

      # An ESTIMATE, and only ever offered as one: the media still to render, at the
      # rate this run has actually managed, minus what the item in flight already
      # spent.
      def eta_s
        rate = throughput or return nil
        return nil unless working?

        spent = working_item&.wall_s.to_f
        [ (remaining_media_s * rate) - spent, 0 ].max.round
      end
    end

    def call(items, now: Time.current)
      rows = items.map { |item| build(item, now) }
      done = rows.select(&:done)
      Result.new(
        items: rows,
        total_media_s: rows.sum(&:media_s),
        done_media_s: done.sum(&:media_s),
        total_count: rows.size,
        done_count: done.size,
        failed_count: rows.count(&:failed),
        bytes: done.sum(&:bytes),
        started_at: rows.filter_map { |r| r.clip&.created_at }.min,
        elapsed_s: elapsed(rows, now)
      )
    end

    private

    def build(item, now)
      clip = item.clip
      done = clip&.state_done? || false
      working = clip.present? && WORKING_STATES.include?(clip.state)
      Item.new(
        cut_item: item, clip: clip,
        media_s: (item.end_s - item.start_s).to_f,
        # A settled clip's span is start→finish; an in-flight one is still running,
        # so it is measured against now.
        wall_s: clip.nil? ? nil : (done || clip.state_error? ? clip.updated_at - clip.created_at : now - clip.created_at),
        bytes: clip&.size_bytes.to_i,
        done: done, working: working, failed: clip&.state_error? || false
      )
    end

    # The run's own wall clock: from the first item's turn to the last settled one,
    # or to now while anything is still working.
    def elapsed(rows, now)
      started = rows.filter_map { |r| r.clip&.created_at }.min or return nil
      finish = rows.any?(&:working) ? now : rows.filter_map { |r| r.clip&.updated_at }.max
      finish ? finish - started : nil
    end
  end
end
