module Competitors
  # The project's tracked channels as the Niche screen's Channels tab shows them:
  # identity, backfill progress and the latest subscriber count. PURE READ.
  #
  # Deliberately NOT part of the niche dashboard. This list is re-fetched every
  # couple of seconds while a backfill runs, and the dashboard scores every video
  # of every channel — polling that would be absurd. Two queries, no scoring.
  class ChannelList
    Row = Struct.new(:channel, :subscribers, keyword_init: true) do
      def id = channel.id
      def youtube_channel_id = channel.youtube_channel_id
      def title = channel.title.presence || channel.youtube_channel_id
      def handle = channel.handle.presence
      def state = channel.backfill_state
      def collecting? = channel.backfill_active?
      def collected = channel.backfill_done
      # 0 means the total is not known yet — the backfill has not counted the
      # uploads playlist, so progress reads "3/?" rather than "3/0".
      def expected = channel.backfill_total.positive? ? channel.backfill_total : nil
      def error = channel.backfill_error.presence
    end

    def initialize(project)
      @project = project
    end

    def call
      channels = @project.competitor_channels.order(:title, :id).to_a
      subscribers = latest_subscribers(channels.map(&:id))
      channels.map { |channel| Row.new(channel: channel, subscribers: subscribers[channel.id]) }
    end

    private

    # Ascending order means the last row written per channel is its most recent
    # snapshot — one query for the whole list rather than a lookup per channel.
    def latest_subscribers(channel_ids)
      return {} if channel_ids.empty?

      ChannelSnapshot.where(competitor_channel_id: channel_ids)
                     .order(:captured_at, :id)
                     .pluck(:competitor_channel_id, :subscribers)
                     .to_h
    end
  end
end
