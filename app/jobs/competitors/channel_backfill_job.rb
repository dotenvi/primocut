module Competitors
  # Thin ActiveJob wrapper around [[Competitors::Backfill]]: it builds the API
  # client from the environment and delegates. Enqueued by
  # [[Competitors::ChannelRegistration]] only for a channel that is new to the
  # system (global dedup). Runs on the default Solid Queue queue.
  class ChannelBackfillJob < ApplicationJob
    queue_as :default

    def perform(youtube_channel_id)
      Backfill.new(client: Adapters::YoutubeApi.from_env).call(youtube_channel_id)
    end
  end
end
