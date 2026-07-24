module Competitors
  # Backfill the recent uploads of a channel that is new to the system.
  #
  # Runs only for a channel seen for the first time (global dedup): it lists the
  # last N uploads, fetches their metadata in batches (quota-accounted) and
  # stores them in `competitor_videos` with an initial `is_short` and
  # `thumbnail_hash`. It also records the channel's **first snapshot**, so the
  # dashboards have data as soon as a channel is added instead of waiting up to
  # 24h for the first scheduled cycle. The video counters cost nothing extra —
  # they ride along in the same `videos.list` response; only the channel
  # statistics add a call (1 unit).
  #
  # Resilience: any API/thumbnail failure degrades — the channel is marked
  # `backfill_state: "error"` with the message logged, and the worker is never
  # crashed. The channel snapshot is isolated on top of that: losing it never
  # costs the uploads, which are the point of the backfill. Progress is written
  # incrementally so the existing polling can follow it. Ported from the PoC
  # `worker/channel_jobs.py`.
  class Backfill
    def initialize(client:, config: Config.new, thumbnail_fetcher: Thumbnails.method(:fetch_bytes))
      @client = client
      @config = config
      @thumbnail_fetcher = thumbnail_fetcher
    end

    # Collect the last `backfill_limit` uploads of `youtube_channel_id` into
    # competitor_videos, plus the channel's first snapshot.
    def call(youtube_channel_id, now: Time.current)
      channel = CompetitorChannel.find_by(youtube_channel_id:)
      raise ArgumentError, "Channel #{youtube_channel_id.inspect} not found in the database." if channel.nil?

      channel.update!(backfill_state: "running", backfill_error: nil)

      begin
        video_ids = @client.list_uploads_video_ids(channel.uploads_playlist_id, limit: @config.backfill_limit)
        channel.update!(backfill_total: video_ids.size)

        done = 0
        @client.list_videos(video_ids).each do |video|
          store_video(channel, video, now:)
          channel.update!(backfill_done: (done += 1))
        end

        record_channel_snapshot(channel, now:)

        channel.update!(backfill_state: "done")
        Rails.logger.info("Backfill #{youtube_channel_id} done: #{done} video(s), #{@client.units_used} quota unit(s)")
        { channel_id: youtube_channel_id, videos: done, quota_units: @client.units_used }
      rescue StandardError => e
        # Degrade: mark error, log, never crash the worker.
        Rails.logger.error("Backfill failed for #{youtube_channel_id}: #{e.message}")
        channel.update!(backfill_state: "error", backfill_error: e.message)
        { channel_id: youtube_channel_id, error: e.message, quota_units: @client.units_used }
      end
    end

    private

    def store_video(channel, video, now:)
      video_record = channel.competitor_videos.find_or_initialize_by(youtube_video_id: video.video_id)
      video_record.update!(
        title: video.title,
        published_at: video.published_at,
        duration_s: video.duration_s,
        is_short: video.duration_s <= @config.short_max_seconds,
        thumbnail_url: video.thumbnail_url,
        thumbnail_hash: Thumbnails.digest(video.thumbnail_url, fetcher: @thumbnail_fetcher)
      )
      video_record.video_snapshots.create!(
        captured_at: now, views: video.view_count, likes: video.like_count, comments: video.comment_count
      )
    end

    # Record the channel's first statistics snapshot (subscribers/views/videos).
    # Isolated from the collection above: this is the only part that spends a call
    # of its own, and the uploads must survive it failing.
    def record_channel_snapshot(channel, now:)
      stats = @client.get_channels_stats([ channel.youtube_channel_id ])
      if stats.empty?
        Rails.logger.warn("No statistics returned for #{channel.youtube_channel_id}; snapshot skipped")
        return
      end
      st = stats.first
      channel.channel_snapshots.create!(
        captured_at: now, subscribers: st.subscribers, total_views: st.total_views, video_count: st.video_count
      )
    rescue StandardError => e
      # Never let the snapshot break the backfill.
      Rails.logger.error("First channel snapshot failed for #{channel.youtube_channel_id}: #{e.message}")
    end
  end
end
