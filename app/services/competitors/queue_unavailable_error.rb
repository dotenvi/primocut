module Competitors
  # The backfill enqueue could not reach the queue; the channel is left in
  # `backfill_state: "error"` rather than stranded mid-collection. Raised by
  # [[Competitors::ChannelRegistration]].
  class QueueUnavailableError < StandardError; end
end
