module Radar
  # The channel-spread strips for the cards currently on screen, keyed by
  # `[channel id, format]`. One distribution per distinct channel+format — a page
  # of six cards from two channels costs two computations, never six.
  #
  # The strip is decoration: a channel that fails to score simply renders without
  # one (ports the PoC's batched `distributionBatch` + its silent failure path).
  class Spread
    def initialize(rows, config: Metrics::Config.new, now: Time.current)
      @rows = rows
      @config = config
      @now = now
    end

    def call
      @rows.select { |row| row.channel && row.views }
           .to_h { |row| [ [ row.channel.id, row.video_format ], row ] }
           .filter_map { |key, row| distribution(key, row) }
           .to_h
    end

    private

    def distribution(key, row)
      [ key, Metrics::ChannelDistribution.new(row.channel, fmt: row.video_format, config: @config, now: @now).call ]
    rescue StandardError => e
      Rails.logger.warn("radar spread: channel #{row.channel.youtube_channel_id} failed: #{e.message}")
      nil
    end
  end
end
