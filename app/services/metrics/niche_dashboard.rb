module Metrics
  # The niche (project) dashboard payload: the project's channels, the cross-channel
  # outlier ranking, the per-format conditional pattern distributions, the packaging
  # log and the resurgences. PURE READ. Ports the PoC `service.py::project_dashboard`.
  #
  # Each channel is scored once (channel metrics are project-independent) and merged;
  # the project only scopes which channels are ranked and which population feeds the
  # pattern guard. All snapshots for the project's videos load in one grouped query,
  # shared by the VPH and resurgence computations.
  class NicheDashboard
    def initialize(project, config: Config.new, now: Time.current)
      @project = project
      @config = config
      @now = now.to_time
    end

    def call
      channels = @project.competitor_channels.to_a
      all_videos = channels.flat_map { |c| c.competitor_videos.to_a }
      snaps_by_video = snapshots_by_video(all_videos.map(&:id))
      scored = score_channels(channels)

      {
        project: { id: @project.id, name: @project.name },
        channels: channels.map { |c| channel_summary(c) },
        outliers: outliers(scored, snaps_by_video),
        patterns: patterns(scored.map { |s| s.fetch(:scored) }),
        # Audience requests are synthesised from comments by an LLM pass (guideline 9)
        # — a later phase. The key is present so the payload shape is stable.
        audience_requests: [],
        packaging: packaging(all_videos),
        resurgences: resurgences(all_videos, snaps_by_video)
      }
    end

    private

    # [{ channel:, scored: Scored }] — every scored video across the project, tagged
    # with its channel so the outlier payload can name it.
    def score_channels(channels)
      channels.flat_map do |channel|
        ChannelScores.new(channel, config: @config, now: @now).call.scored.values.map do |sc|
          { channel:, scored: sc }
        end
      end
    end

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

    def channel_summary(channel)
      latest = channel.channel_snapshots.order(:captured_at, :id).last
      { channel_id: channel.youtube_channel_id, title: channel.title, subscribers: latest&.subscribers }
    end

    def outliers(scored, snaps_by_video)
      ranked = scored.select { |s| s.fetch(:scored).score.band }
                     .sort_by { |s| -s.fetch(:scored).score.median_multiple }
      by_format(ranked) { |s| s.fetch(:scored).is_short }
        .transform_values { |rows| rows.map { |s| outlier_payload(s, snaps_by_video) } }
    end

    def outlier_payload(entry, snaps_by_video)
      sc = entry.fetch(:scored)
      channel = entry.fetch(:channel)
      s = sc.score
      snaps = snaps_by_video[sc.competitor_video_id] || []
      {
        video_id: sc.youtube_video_id, title: sc.title, is_short: sc.is_short, views: sc.views,
        median_multiple: s.median_multiple, band: s.band, band_basis: s.band_basis,
        percentile: s.percentile, band_cutoffs: s.band_cutoffs, provisional: s.provisional,
        channel_id: channel.youtube_channel_id, channel_title: channel.title,
        current_vph: Core.current_vph(core_snaps(snaps), window_hours: @config.vph_current_window_hours)
      }
    end

    # Conditional distributions per format, per attribute source. The outlier group
    # is the banded mature videos with a row for that source; the control is the
    # band-less mature ones. Provisional/insufficient videos are censored (status !=
    # ok). An un-enriched video is *unknown*, not "attribute absent", so each source's
    # groups are restricted to the videos that actually have a row for it.
    def patterns(all_scored)
      by_format(all_scored.flatten) { |sc| sc.is_short }.transform_values { |scs| patterns_for(scs) }
    end

    def patterns_for(scored_list)
      mature = scored_list.select { |sc| sc.score.status == "ok" }
      return [] if mature.empty?

      rows = VideoAttribute.where(competitor_video_id: mature.map(&:competitor_video_id))
      by_source = rows.group_by(&:source)
      out = []
      by_source.keys.sort.each do |source|
        attrs_by_id = by_source[source].to_h { |r| [ r.competitor_video_id, r.attrs ] }
        outlier_attrs = []
        control_attrs = []
        mature.each do |sc|
          attrs = attrs_by_id[sc.competitor_video_id]
          next if attrs.nil?

          (sc.score.band ? outlier_attrs : control_attrs) << attrs
        end
        Patterns.conditional_patterns(outlier_attrs, control_attrs, z: @config.pattern_confidence, source:).each do |p|
          out << {
            attribute: p.attribute, freq_outlier: p.freq_outlier, ci_outlier: p.ci_outlier,
            freq_control: p.freq_control, ci_control: p.ci_control, lift: p.lift,
            n_outlier: p.n_outlier, n_control: p.n_control, verdict: p.verdict, source: p.source
          }
        end
      end
      out
    end

    def packaging(videos)
      yt_by_id = videos.to_h { |v| [ v.id, v.youtube_video_id ] }
      title_by_id = videos.to_h { |v| [ v.id, v.title ] }
      channel_of = videos.to_h { |v| [ v.id, v.competitor_channel ] }
      PackagingChange.where(competitor_video_id: videos.map(&:id)).order(:detected_at, :id).map do |ch|
        delta = ch.vph_after && ch.vph_before ? ch.vph_after - ch.vph_before : nil
        channel = channel_of[ch.competitor_video_id]
        {
          video_id: yt_by_id[ch.competitor_video_id], channel_id: channel&.youtube_channel_id,
          title: title_by_id[ch.competitor_video_id] || "", channel_title: channel&.title,
          field: ch.field, detected_at: ch.detected_at.iso8601,
          vph_before: ch.vph_before, vph_after: ch.vph_after, delta:
        }
      end
    end

    def resurgences(videos, snaps_by_video)
      resurgent = videos.filter_map do |v|
        res = resurgence(v, snaps_by_video[v.id] || [])
        next unless res.is_resurgent

        [ v.is_short, {
          video_id: v.youtube_video_id, channel_id: v.competitor_channel.youtube_channel_id,
          title: v.title, ratio: res.ratio, current_vph: res.current_vph
        } ]
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
