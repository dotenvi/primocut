module Competitors
  # What an analysis of `kind` would cost a project, computed BEFORE the click:
  # which videos it would spend an LLM call on, and how many are already cached.
  # PURE READ — it asks the very same gate the job uses, so the price on the
  # button cannot disagree with what the click then does.
  #
  # The target population depends on the kind, and the difference matters:
  # `title`/`thumbnail` feed the two-group pattern comparison, so BOTH sides need
  # the attribute — every **mature** video is a target. `comments` summarise one
  # group, so they target only the **definitive outliers**; a provisional video may
  # still fall back to ordinary as its score settles, and synthesising it would be
  # money spent on a verdict that has not happened yet.
  class AnalysisPlan
    # The kinds that feed the pattern comparison rather than a single group.
    PATTERN_KINDS = %w[title thumbnail].freeze

    Result = Struct.new(:kind, :pending, :cached, keyword_init: true) do
      def pending_count = pending.size
      def total = pending.size + cached
      def any? = pending.any?
    end

    def initialize(project, kind:, analyzer: nil, config: Metrics::Config.new, now: Time.current)
      @project = project
      @kind = kind
      @analyzer = analyzer
      @config = config
      @now = now
    end

    def call
      # Up front, not incidentally through the first gate: a bogus kind must be
      # refused even for a project that has nothing to price.
      VideoAnalysis.source_for(@kind)

      pending = []
      cached = 0

      target_ids.each do |youtube_video_id|
        gate(youtube_video_id) ? pending << youtube_video_id : cached += 1
      end

      Result.new(kind: @kind, pending: pending, cached: cached)
    end

    private

    def analyzer = @analyzer ||= VideoAnalysis.new

    # nil means "cached, a re-run is free". A video that cannot be gated at all —
    # unknown, or content not hashable yet — counts as pending on purpose: the job
    # attempts it and surfaces a visible error, which beats hiding it from the
    # total. Only those two gating failures are caught; anything else is a bug and
    # must not be silently priced in.
    def gate(youtube_video_id)
      !analyzer.plan(youtube_video_id, kind: @kind).nil?
    rescue VideoAnalysis::UnknownVideo, VideoAnalysis::NotAnalyzable
      true
    end

    def target_ids
      mature = scored.select { |sc| sc.score.status == "ok" }
      keep = PATTERN_KINDS.include?(@kind) ? mature : mature.select { |sc| sc.score.band }
      keep.map(&:youtube_video_id)
    end

    def scored
      @project.competitor_channels.flat_map do |channel|
        Metrics::ChannelScores.new(channel, config: @config, now: @now).call.scored.values
      end
    end
  end
end
