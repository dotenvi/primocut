module Metrics
  # The channel dashboard payload: header stats, per-format band baselines, the
  # outlier ranking, engagement medians, upload cadence, the packaging log and the
  # resurgence list. PURE READ. Ports the PoC `service.py::channel_dashboard`.
  #
  # Every population is split by format (Shorts and long-form are different
  # products). Snapshots for the whole channel are loaded once and grouped, so
  # engagement and resurgence share a single query rather than scanning per video.
  class ChannelDashboard
    def initialize(channel, config: Config.new, now: Time.current)
      @channel = channel
      @config = config
      @now = now.to_time
    end

    def call
      result = ChannelScores.new(@channel, config: @config, now: @now).call
      videos = @channel.competitor_videos.to_a
      snaps_by_video = snapshots_by_video(videos.map(&:id))
      latest_snap = @channel.channel_snapshots.order(:captured_at, :id).last

      {
        channel: channel_meta(latest_snap),
        baselines: baselines(result.rulers),
        outliers: outliers(result.scored),
        engagement: engagement(videos, snaps_by_video),
        cadence: cadence_payload(videos),
        packaging: packaging(videos),
        resurgences: resurgences(videos, snaps_by_video)
      }
    end

    private

    # All snapshots for the channel's videos in one query, grouped and time-ordered.
    def snapshots_by_video(ids)
      return {} if ids.empty?

      VideoSnapshot.where(competitor_video_id: ids).order(:captured_at, :id).group_by(&:competitor_video_id)
    end

    def core_snaps(snaps)
      snaps.map { |s| Core::Snap.new(captured_at: s.captured_at.to_time, views: s.views) }
    end

    def by_format(items)
      ChannelScores::FORMATS.to_h { |fmt, is_short| [ fmt, items.select { |it| yield(it) == is_short } ] }
    end

    def channel_meta(snap)
      {
        channel_id: @channel.youtube_channel_id, title: @channel.title, handle: @channel.handle,
        subscribers: snap&.subscribers, total_views: snap&.total_views, video_count: snap&.video_count
      }
    end

    def baselines(rulers)
      rulers.transform_values do |r|
        r && { median: r.median, sample: r.sample_size, basis: r.basis, cutoffs: r.cutoffs, thresholds: r.thresholds }
      end
    end

    def outliers(scored)
      ranked = scored.values.select { |sc| sc.score.band }.sort_by { |sc| -sc.score.median_multiple }
      by_format(ranked, &:is_short).transform_values { |scs| scs.map { |sc| outlier_payload(sc) } }
    end

    def outlier_payload(scored)
      s = scored.score
      {
        video_id: scored.youtube_video_id, title: scored.title, is_short: scored.is_short,
        views: scored.views, median_multiple: s.median_multiple, band: s.band,
        band_basis: s.band_basis, percentile: s.percentile, band_cutoffs: s.band_cutoffs,
        provisional: s.provisional
      }
    end

    # Engagement medians over the channel's videos that have a snapshot, per format:
    # a Short's like rate is structurally unlike a long-form video's.
    def engagement(videos, snaps_by_video)
      by_format(videos, &:is_short).transform_values do |vids|
        like_rates = []
        comment_rates = []
        vids.each do |v|
          latest = (snaps_by_video[v.id] || []).last
          next if latest.nil?

          e = Core.engagement_rates(latest.views, latest.likes, latest.comments)
          like_rates << e.like_rate unless e.like_rate.nil?
          comment_rates << e.comment_rate unless e.comment_rate.nil?
        end
        { like_rate_median: Core.median(like_rates), comment_rate_median: Core.median(comment_rates) }
      end
    end

    def cadence_payload(videos)
      metas = videos.map { |v| Core::VideoMeta.new(published_at: v.published_at&.to_time, is_short: v.is_short, duration_s: v.duration_s) }
      cad = Core.cadence(metas, now: @now)
      {
        uploads_per_week: cad.uploads_per_week,
        by_weekday: cad.by_weekday.sort.to_h.transform_keys(&:to_s),
        by_hour: cad.by_hour.sort.to_h.transform_keys(&:to_s),
        duration_by_format: cad.duration_by_format
      }
    end

    def packaging(videos)
      yt_by_id = videos.to_h { |v| [ v.id, v.youtube_video_id ] }
      title_by_id = videos.to_h { |v| [ v.id, v.title ] }
      PackagingChange.where(competitor_video_id: videos.map(&:id)).order(:detected_at, :id).map do |ch|
        delta = ch.vph_after && ch.vph_before ? ch.vph_after - ch.vph_before : nil
        {
          video_id: yt_by_id[ch.competitor_video_id], title: title_by_id[ch.competitor_video_id] || "",
          field: ch.field, detected_at: ch.detected_at.iso8601,
          vph_before: ch.vph_before, vph_after: ch.vph_after, delta:
        }
      end
    end

    def resurgences(videos, snaps_by_video)
      resurgent = videos.filter_map do |v|
        res = resurgence(v, snaps_by_video[v.id] || [])
        next unless res.is_resurgent

        [ v.is_short, { video_id: v.youtube_video_id, title: v.title, ratio: res.ratio, current_vph: res.current_vph, recent_avg_vph: res.recent_avg_vph } ]
      end
      by_format(resurgent) { |r| r[0] }.transform_values { |rows| rows.map { |r| r[1] } }
    end

    def resurgence(video, snaps)
      Core.resurgence(
        core_snaps(snaps), published_at: video.published_at&.to_time, now: @now,
        min_age_days: @config.resurgence_min_age_days, k: @config.resurgence_k,
        baseline_days: @config.resurgence_baseline_days, min_vph: @config.resurgence_min_vph,
        window_hours: @config.vph_current_window_hours
      )
    end
  end
end
