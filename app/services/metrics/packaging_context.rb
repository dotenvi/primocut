require "set"

module Metrics
  # Deterministic INPUT for AI packaging (no LLM). Reads a project's Phase 2 patterns
  # and re-presents them under the three lenses the packaging prompt cites, plus real
  # outlier examples. Everything is a PURE READ over the same scoring the dashboard
  # computes — scores are never stored. Ported from the PoC `metrics/packaging_signals.py`.
  #
  # - **differential**  — the Wilson-gated conditional-distribution patterns that
  #   SEPARATE outliers from the censored control (reused via the same
  #   [[Metrics::Patterns]] primitive the niche view uses, so the two can never disagree).
  # - **conventions**   — booleans near-universal across the WHOLE mature niche
  #   (freq >= `packaging_convention_floor`): what the niche REQUIRES (table-stakes),
  #   not what distinguishes a winner. A separating attribute is a lever, never a
  #   convention, so anything already a differential is excluded.
  # - **carries_value** — recurring NON-boolean values (the "name that carries", from
  #   `title_llm.person_names`) disproportionate in outliers, guarded by a min-videos
  #   AND min-lift floor (the never-invent-a-pattern rule for values).
  #
  # A niche where nothing separates and nothing carries is reported `flat: true` so a
  # generator stays honest (packaging is not the lever) instead of inventing differentials.
  class PackagingContext
    ATTR_SOURCES = [ Attributes::SOURCE, "title_llm", "thumbnail_llm" ].freeze
    # The value fields a carries-value pattern is mined from, per attribute source.
    CARRIES_FIELDS = { "title_llm" => %w[person_names] }.freeze

    def initialize(project, config: Config.new, now: Time.current, fmt: nil)
      @project = project
      @config = config
      @now = now
      @fmt = fmt || config.packaging_format
    end

    def call
      scored_fmt = scored.select { |sc| format_of(sc) == @fmt }
      mature = scored_fmt.select { |sc| sc.score.status == "ok" }
      outliers = mature.select { |sc| sc.score.band }

      differential = differential(scored_fmt)
      diff_attrs = differential.map { |d| d[:attribute] }.to_set
      conventions = conventions(mature, diff_attrs)
      carries = carries_value(mature, outliers)

      {
        niche: { project_name: @project.name, channels: channels.size, outliers: outliers.size, format: @fmt },
        differential:, conventions:, carries_value: carries, examples: examples(outliers),
        # Conventions may still exist (everyone does X), but a requirement is not a lever.
        flat: differential.empty? && carries.values.all?(&:empty?)
      }
    end

    private

    def channels = @channels ||= @project.competitor_channels.to_a

    def scored
      @scored ||= channels.flat_map { |channel| ChannelScores.new(channel, config: @config, now: @now).call.scored.values }
    end

    def format_of(sc) = sc.is_short ? "short" : "long"

    # The conditional distributions that separate outliers from control, per source.
    # Mirrors `NicheDashboard#patterns_for` so packaging never disagrees with the niche.
    def differential(scored_list)
      mature = scored_list.select { |sc| sc.score.status == "ok" }
      return [] if mature.empty?

      by_source = VideoAttribute.where(competitor_video_id: mature.map(&:competitor_video_id)).group_by(&:source)
      by_source.keys.sort.flat_map do |source|
        attrs_by_id = by_source[source].to_h { |r| [ r.competitor_video_id, r.attrs ] }
        outlier_attrs = []
        control_attrs = []
        mature.each do |sc|
          attrs = attrs_by_id[sc.competitor_video_id]
          next if attrs.nil?

          (sc.score.band ? outlier_attrs : control_attrs) << attrs
        end
        Patterns.conditional_patterns(outlier_attrs, control_attrs, z: @config.pattern_confidence, source:).map do |p|
          { attribute: p.attribute, source: p.source, freq_outlier: p.freq_outlier, freq_control: p.freq_control, lift: p.lift, verdict: p.verdict }
        end
      end
    end

    def conventions(mature, diff_attrs)
      floor = @config.packaging_convention_floor
      out = []
      ATTR_SOURCES.each do |source|
        attrs = grouped_attributes(mature, source)
        next if attrs.empty?

        n = attrs.size
        boolean_keys(attrs).sort.each do |key|
          next if diff_attrs.include?(key)

          freq = attrs.values.count { |a| a[key] == true }.to_f / n
          out << { attribute: key, source:, freq:, n: } if freq >= floor
        end
      end
      out.sort_by { |c| -c[:freq] }
    end

    def carries_value(mature, outliers)
      out_ids = outliers.map(&:competitor_video_id).to_set
      CARRIES_FIELDS.each_with_object({}) do |(source, fields), result|
        attrs = grouped_attributes(mature, source)
        out_analyzed = attrs.keys.select { |id| out_ids.include?(id) }
        ctl_analyzed = attrs.keys.reject { |id| out_ids.include?(id) }
        fields.each { |field| result[field] = mine_field(attrs, out_analyzed, ctl_analyzed, field) }
      end
    end

    def mine_field(attrs, out_ids, ctl_ids, field)
      acc = Hash.new { |h, k| h[k] = { spellings: Hash.new(0), out: Set.new, ctl: Set.new } }
      (out_ids + ctl_ids).each do |vid|
        values(attrs[vid][field]).each do |raw|
          key = raw.strip.downcase
          next if key.empty?

          entry = acc[key]
          entry[:spellings][raw] += 1
          (out_ids.include?(vid) ? entry[:out] : entry[:ctl]) << vid
        end
      end

      n_out = out_ids.size
      n_ctl = ctl_ids.size
      min_videos = @config.packaging_carries_value_min_videos
      min_lift = @config.packaging_carries_value_min_lift
      rows = acc.filter_map do |_key, entry|
        v_out = entry[:out].size
        next if v_out < min_videos

        freq_out = n_out.positive? ? v_out.to_f / n_out : 0.0
        freq_ctl = n_ctl.positive? ? entry[:ctl].size.to_f / n_ctl : 0.0
        lift = freq_ctl.positive? ? freq_out / freq_ctl : nil
        next if !lift.nil? && lift < min_lift

        { value: entry[:spellings].max_by { |spelling, count| [ count, -spelling.length ] }.first,
          videos_outlier: v_out, videos_control: entry[:ctl].size, lift: }
      end
      # Descending by (lift present, lift, videos_outlier) — a nil lift (no control hits) sorts to the top.
      rows.sort_by { |r| [ r[:lift].nil? ? 0 : 1, r[:lift] || 0.0, r[:videos_outlier] ] }.reverse
    end

    # The top outliers by median multiple, with their analyzed attributes — real
    # titles and real measured attributes the prompt can reference, never fabricated.
    def examples(outliers)
      top = outliers.sort_by { |sc| -sc.score.median_multiple }.first(@config.packaging_examples)
      ids = top.map(&:competitor_video_id)
      title_attrs = VideoAttribute.where(competitor_video_id: ids, source: "title_llm").index_by(&:competitor_video_id)
      thumb_attrs = VideoAttribute.where(competitor_video_id: ids, source: "thumbnail_llm").index_by(&:competitor_video_id)

      top.map do |sc|
        { video_id: sc.youtube_video_id, title: sc.title, band: sc.score.band, median_multiple: sc.score.median_multiple,
          title_attrs: title_attrs[sc.competitor_video_id]&.attrs || {}, thumb_attrs: thumb_attrs[sc.competitor_video_id]&.attrs || {} }
      end
    end

    def grouped_attributes(videos, source)
      VideoAttribute.where(competitor_video_id: videos.map(&:competitor_video_id), source:).to_h { |r| [ r.competitor_video_id, r.attrs ] }
    end

    def boolean_keys(attrs)
      attrs.values.flat_map { |a| a.select { |_k, v| [ true, false ].include?(v) }.keys }.uniq
    end

    def values(raw)
      return [] unless raw.is_a?(Array)

      raw.select { |v| v.is_a?(String) && v.strip.present? }
    end
  end
end
