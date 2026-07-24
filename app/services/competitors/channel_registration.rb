module Competitors
  # Register / detach competitor channels within a project. Shared by the (future)
  # controller and CLI. Ported from the PoC `worker/channels.py`.
  #
  # Registration resolves the reference with a single fast API call, then:
  # - channel NEW to the system → insert + link + enqueue the async backfill;
  # - channel ALREADY known      → only link (global dedup, no re-collection),
  #   reactivating it if it was an orphan — unless its backfill never completed,
  #   which re-enqueues it.
  #
  # The channel row is committed before the enqueue, so a broker failure must
  # leave the channel reported as failed (`error`) rather than stuck collecting
  # forever: nothing else moves that state.
  class ChannelRegistration
    # Backfill states of a channel that holds no collection worth deduping
    # against: "pending" never reached the queue, "error" never finished.
    # Re-registering such a channel collects it instead of skipping it.
    NEVER_COLLECTED = %w[pending error].freeze

    def initialize(client:, enqueuer: nil)
      @client = client
      @enqueuer = enqueuer || method(:enqueue_default)
    end

    # Register (resolve + link) a channel in a project. Enqueues a backfill only
    # when the channel is new to the system, or when a known one never collected.
    # Raises KeyError if the project is missing; the client's resolution errors
    # (YoutubeApi::Error / ArgumentError) propagate.
    def register(project_id:, reference:)
      info = @client.get_channel(**Adapters::YoutubeApi.parse_channel_reference(reference))

      raise KeyError, project_id unless Project.exists?(project_id)

      channel = CompetitorChannel.find_by(youtube_channel_id: info.channel_id)
      is_new = channel.nil?
      if is_new
        channel = CompetitorChannel.create!(
          youtube_channel_id: info.channel_id, handle: info.handle, title: info.title,
          uploads_playlist_id: info.uploads_playlist_id, active: true, backfill_state: "pending"
        )
        reactivated = false
        retry_backfill = true
      else
        reactivated = !channel.active?
        channel.update!(active: true) if reactivated
        # Dedup skips re-collection, but only a channel that actually collected
        # has anything to dedup against: one whose backfill never ran would be
        # stranded, since registering is the only path that enqueues it.
        retry_backfill = NEVER_COLLECTED.include?(channel.backfill_state)
      end

      result = { channel_id: info.channel_id, title: info.title,
                 existing: !is_new, linked: link(project_id, channel), reactivated: }

      unless retry_backfill
        Rails.logger.info("Linked existing channel #{info.channel_id} to project #{project_id} (no backfill).")
        return result.merge(backfill: "skipped")
      end

      result.merge(backfill: "queued", **enqueue_backfill(channel))
    end

    # Detach a channel from a project, deactivating it if orphaned. Keeps all
    # data. Raises KeyError if the project is missing.
    def self.detach(project_id:, youtube_channel_id:)
      raise KeyError, project_id unless Project.exists?(project_id)

      channel = CompetitorChannel.find_by(youtube_channel_id:)
      detached = deactivated = false
      if channel
        link = ProjectChannel.find_by(project_id:, competitor_channel_id: channel.id)
        if link
          link.destroy!
          detached = true
        end
        if channel.active? && channel.project_channels.count.zero?
          channel.update!(active: false)
          deactivated = true
        end
      end

      Rails.logger.info("Detached channel #{youtube_channel_id} from project #{project_id} (deactivated=#{deactivated}).")
      { channel_id: youtube_channel_id, detached:, deactivated: }
    end

    private

    # Link the channel to the project; returns whether a NEW link was created
    # (an existing link is left untouched — that is the cross-project dedup).
    def link(project_id, channel)
      ProjectChannel.create!(project_id:, competitor_channel_id: channel.id)
      true
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      false
    end

    # Enqueue the backfill and record the job on the channel. A broker failure is
    # recorded on the (already-committed) channel row and re-raised, so the caller
    # answers for the failed request instead of leaving a silent dead collection.
    def enqueue_backfill(channel)
      job =
        begin
          @enqueuer.call(channel)
        rescue StandardError => e
          Rails.logger.error("Could not enqueue the backfill for #{channel.youtube_channel_id}: #{e.message}")
          channel.update!(backfill_state: "error", backfill_error: e.message, backfill_rq_job_id: nil)
          raise QueueUnavailableError, e.message
        end

      channel.update!(backfill_state: "queued", backfill_error: nil, backfill_rq_job_id: job.job_id)
      Rails.logger.info("Enqueued backfill for #{channel.youtube_channel_id} (job #{job.job_id})")
      { job_id: job.job_id }
    end

    def enqueue_default(channel)
      ChannelBackfillJob.perform_later(channel.youtube_channel_id)
    end
  end
end
