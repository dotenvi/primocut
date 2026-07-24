module Metrics
  # The full per-video report payload: metadata, the raw snapshot series, live VPH
  # (current + pairwise), the outlier verdict, engagement, resurgence, the attributes
  # by source, comment collection/synthesis state, and the packaging change log.
  # PURE READ. Ports the PoC `service.py::video_report`.
  #
  # Takes an already-scoped CompetitorVideo — the per-project leakage guard (the
  # video must belong to a channel in the project) is the controller's job, exactly
  # as the PoC checks `video.channel_id == channel_id` at the request boundary.
  class VideoReport
    COMMENT_SYNTHESIS_KIND = "comment_synthesis"

    def initialize(video, config: Config.new, now: Time.current)
      @video = video
      @channel = video.competitor_channel
      @config = config
      @now = now.to_time # normalise to a plain Time so Core arithmetic never mixes zone types
    end

    def call
      snaps = @video.video_snapshots.order(:captured_at, :id).to_a
      core_snaps = snaps.map { |s| Core::Snap.new(captured_at: s.captured_at.to_time, views: s.views) }
      score = ChannelScores.new(@channel, config: @config, now: @now).call.scored[@video.id]
      latest = snaps.last
      eng = latest ? Core.engagement_rates(latest.views, latest.likes, latest.comments) : Core::Engagement.new(like_rate: nil, comment_rate: nil)
      res = resurgence(core_snaps)

      {
        video: video_meta,
        snapshots: snaps.map { |s| { captured_at: s.captured_at.iso8601, views: s.views, likes: s.likes, comments: s.comments } },
        vph: {
          current: Core.current_vph(core_snaps, window_hours: @config.vph_current_window_hours),
          series: Core.vph_series(core_snaps).map { |p| { from: p.from_at.iso8601, to: p.to_at.iso8601, hours: p.hours, vph: p.vph } }
        },
        outlier: outlier_payload(score),
        engagement: { like_rate: eng.like_rate, comment_rate: eng.comment_rate },
        resurgence: { is_resurgent: res.is_resurgent, ratio: res.ratio, current_vph: res.current_vph, recent_avg_vph: res.recent_avg_vph },
        attributes: attributes_by_source,
        comments: { collected: @video.video_comments.count, state: @video.comments_state, error: @video.comments_error },
        comment_synthesis: comment_synthesis,
        packaging_changes: packaging_changes
      }
    end

    private

    def video_meta
      {
        youtube_video_id: @video.youtube_video_id,
        title: @video.title,
        published_at: @video.published_at&.iso8601,
        duration_s: @video.duration_s,
        is_short: @video.is_short,
        thumbnail_url: @video.thumbnail_url
      }
    end

    def resurgence(core_snaps)
      Core.resurgence(
        core_snaps, published_at: @video.published_at&.to_time, now: @now,
        min_age_days: @config.resurgence_min_age_days, k: @config.resurgence_k,
        baseline_days: @config.resurgence_baseline_days, min_vph: @config.resurgence_min_vph,
        window_hours: @config.vph_current_window_hours
      )
    end

    def outlier_payload(score)
      fmt = @video.is_short ? "short" : "long"
      return { status: "insufficient_sample", median_multiple: nil, band: nil, band_basis: "", percentile: nil, band_cutoffs: {}, provisional: false, baseline: nil, sample_size: 0, format: fmt } if score.nil?

      s = score.score
      {
        median_multiple: s.median_multiple, band: s.band, band_basis: s.band_basis,
        percentile: s.percentile, band_cutoffs: s.band_cutoffs, provisional: s.provisional,
        baseline: s.baseline, sample_size: s.sample_size, status: s.status, format: fmt
      }
    end

    # One entry per attribute source that exists for the video (syntactic today; the
    # LLM sources appear once enrichment lands). A source nobody produced is simply
    # absent — an un-enriched video is "unknown", not "attribute absent".
    def attributes_by_source
      @video.video_attributes.each_with_object({}) do |row, acc|
        acc[row.source] = { values: row.attrs, state: row.state, error: row.error, updated_at: row.updated_at&.iso8601 }
      end
    end

    def comment_synthesis
      row = @video.video_enrichments.find_by(kind: COMMENT_SYNTHESIS_KIND)
      return nil if row.nil?

      { values: row.payload, state: row.state, error: row.error, updated_at: row.updated_at&.iso8601 }
    end

    def packaging_changes
      @video.packaging_changes.order(:detected_at, :id).map do |c|
        {
          field: c.field, old_value: c.old_value, new_value: c.new_value,
          detected_at: c.detected_at.iso8601, vph_before: c.vph_before, vph_after: c.vph_after
        }
      end
    end
  end
end
