module Competitors
  # One competitor-snapshot collection cycle. A single service drives both
  # cadences (see `config/recurring.yml`):
  #   scope="all"    → snapshot every video of every active channel (daily);
  #   scope="recent" → snapshot only videos published within `recent_days` (6h).
  #
  # Each cycle also detects newly published videos (top of the uploads scan) and
  # packaging changes (title string; thumbnail by BYTE hash — the URL is not
  # trusted) against the last-known state, then persists the deterministic metrics
  # artifacts the data model asks for (syntactic title attributes + packaging
  # impact whose window has elapsed). Nothing here ever calls an LLM.
  #
  # Resilience: channels are processed in isolation — a failure on one is logged
  # and the cycle moves on to the next; it never aborts the whole cycle. Orphan
  # channels (active=false) are excluded, so re-linking a channel resumes its
  # collection. Ported from the PoC `worker/snapshot_jobs.py`. Outlier-event
  # emission and comment collection are sibling steps added in later slices.
  class SnapshotCycle
    VALID_SCOPES = %w[all recent].freeze

    def initialize(client:, config: Config.new, thumbnail_fetcher: Thumbnails.method(:fetch_bytes))
      @client = client
      @config = config
      @thumbnail_fetcher = thumbnail_fetcher
    end

    # Run one cycle. `channel_id` limits it to a single (active) channel — used by
    # a manual one-shot.
    def call(scope: "all", channel_id: nil, now: Time.current)
      unless VALID_SCOPES.include?(scope)
        raise ArgumentError, "scope must be one of #{VALID_SCOPES.inspect}, got #{scope.inspect}"
      end
      since = scope == "recent" ? now - @config.recent_days.days : nil

      channels = CompetitorChannel.where(active: true).order(:youtube_channel_id)
      channels = channels.where(youtube_channel_id: channel_id) if channel_id
      targets = channels.to_a

      channels_done = videos_done = packaging_changes = 0
      targets.each do |channel|
        n_videos, n_changes = snapshot_channel(channel, scope:, since:, now:)
        channels_done += 1
        videos_done += n_videos
        packaging_changes += n_changes
      rescue StandardError => e # per-channel isolation: log and keep going
        Rails.logger.error("snapshot(#{scope}): channel #{channel.youtube_channel_id} failed: #{e.message}")
        next
      end

      # Deterministic, offline persistence step: refresh the syntactic title
      # attributes for the processed channels and fill packaging impact for changes
      # whose window has elapsed. Isolated so a failure here never affects the
      # collected snapshots.
      persist_metrics_artifacts(targets, now:)

      result = {
        scope:, channels: channels_done, videos: videos_done,
        packaging_changes:, comments: 0, quota_units: @client.units_used
      }
      record_cycle_done(result, now:)

      Rails.logger.info(
        "snapshot(#{scope}) done: #{channels_done} channel(s), #{videos_done} video(s), " \
        "#{packaging_changes} packaging change(s), #{@client.units_used} quota unit(s)"
      )
      result
    end

    private

    # Collect one channel. Returns [videos_snapshotted, packaging_changes].
    def snapshot_channel(channel, scope:, since:, now:)
      # -- 1. network reads (kept outside the write transaction) --
      stats = @client.get_channels_stats([ channel.youtube_channel_id ])
      top_ids = @client.list_uploads_video_ids(channel.uploads_playlist_id, limit: @config.uploads_scan_limit)

      existing_ids = channel.competitor_videos.pluck(:youtube_video_id)
      scoped = channel.competitor_videos
      scoped = scoped.where.not(published_at: nil).where(published_at: since..) if since
      scoped_ids = scoped.pluck(:youtube_video_id)

      new_ids = top_ids - existing_ids
      # dedup while preserving order: scoped videos first, then newly detected ones
      target_ids = (scoped_ids + new_ids).uniq
      videos = target_ids.any? ? @client.list_videos(target_ids) : []
      hashes = videos.to_h { |v| [ v.video_id, Thumbnails.digest(v.thumbnail_url, fetcher: @thumbnail_fetcher) ] }

      existing_set = existing_ids.to_set
      changes = 0

      # -- 2. single write transaction for this channel --
      ActiveRecord::Base.transaction do
        if stats.any?
          st = stats.first
          channel.channel_snapshots.create!(
            captured_at: now, subscribers: st.subscribers, total_views: st.total_views, video_count: st.video_count
          )
        end

        videos.each do |v|
          record =
            if existing_set.include?(v.video_id)
              vr = channel.competitor_videos.find_by!(youtube_video_id: v.video_id)
              changes += detect_packaging(channel, vr, v, hashes[v.video_id], now)
              vr
            else
              channel.competitor_videos.create!(
                youtube_video_id: v.video_id, title: v.title, published_at: v.published_at,
                duration_s: v.duration_s, is_short: v.duration_s <= @config.short_max_seconds,
                thumbnail_url: v.thumbnail_url, thumbnail_hash: hashes[v.video_id]
              )
            end
          record.video_snapshots.create!(
            captured_at: now, views: v.view_count, likes: v.like_count, comments: v.comment_count
          )
        end
      end

      [ videos.size, changes ]
    end

    # Compare title + thumbnail hash against the last-known state; record any change
    # and update the stored state. Returns the number of changes recorded.
    def detect_packaging(channel, record, video, new_hash, now)
      old_title = record.title
      old_hash = record.thumbnail_hash
      changes = 0

      if old_title.present? && video.title.present? && old_title != video.title
        record.packaging_changes.create!(field: "title", old_value: old_title, new_value: video.title, detected_at: now)
        record.update!(title: video.title)
        emit_packaging_changed(channel, record, "title", old_title, video.title, now)
        changes += 1
      end

      if old_hash.present? && new_hash.present? && old_hash != new_hash
        # Same URL can serve different bytes — the hash is the source of truth.
        record.packaging_changes.create!(field: "thumbnail", old_value: old_hash, new_value: new_hash, detected_at: now)
        record.update!(thumbnail_url: video.thumbnail_url, thumbnail_hash: new_hash)
        emit_packaging_changed(channel, record, "thumbnail", old_hash, new_hash, now)
        changes += 1
      elsif old_hash.blank? && new_hash.present? # first successful hash — fill silently
        record.update!(thumbnail_url: video.thumbnail_url, thumbnail_hash: new_hash)
      end

      changes
    end

    # Record the packaging change as a niche event (project_id NULL; attributed on
    # read). Emitted in the same transaction as the change itself.
    def emit_packaging_changed(channel, record, field, old_value, new_value, now)
      Event.create!(
        category: "niche", event_type: "packaging_changed", severity: "info",
        competitor_channel_id: channel.id, competitor_video_id: record.id, occurred_at: now,
        payload: { "field" => field, "old_value" => old_value, "new_value" => new_value }
      )
    end

    def persist_metrics_artifacts(channels, now:)
      video_ids = CompetitorVideo.where(competitor_channel_id: channels.map(&:id)).pluck(:youtube_video_id)
      attrs = Metrics::Attributes.refresh_syntactic_attributes(video_ids)
      filled = Metrics::Impact.backfill_packaging_impact(now:)
      Rails.logger.info("metrics artifacts: #{attrs} attribute row(s), #{filled} packaging impact(s)")
    rescue StandardError => e # never let persistence break the collection cycle
      Rails.logger.error("metrics artifact persistence failed: #{e.message}")
    end

    # A born-resolved ops record of the cycle: it carries the quota accounting the
    # activity log reports and, being resolved at birth, never shows as an open
    # alert. Isolated: a log-write failure must not fail an otherwise-good cycle.
    def record_cycle_done(result, now:)
      Event.create!(
        category: "ops", event_type: "cycle_done", severity: "info",
        occurred_at: now, resolved_at: now, payload: result.transform_keys(&:to_s)
      )
    rescue StandardError => e
      Rails.logger.error("cycle_done log failed: #{e.message}")
    end
  end
end
