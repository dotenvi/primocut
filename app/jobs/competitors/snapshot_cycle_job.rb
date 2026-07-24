module Competitors
  # Thin ActiveJob wrapper around [[Competitors::SnapshotCycle]]: it builds the API
  # client from the environment and delegates. Enqueued by the two
  # `config/recurring.yml` cadences (daily `all`, 6-hourly `recent`) — the PoC
  # scheduler process is gone. Runs on the default Solid Queue queue.
  class SnapshotCycleJob < ApplicationJob
    queue_as :default

    def perform(scope = "all")
      SnapshotCycle.new(client: Adapters::YoutubeApi.from_env).call(scope:)
    end
  end
end
