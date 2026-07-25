module Cuts
  # The MACRO topic selection: window the transcript, extract topics via the LLM
  # per window (with retry and controlled degradation), resolve the model's segment
  # indices into real seconds, consolidate window-overlap duplicates, and persist
  # the set. Ported from the PoC `analysis/topics.py` + `analysis/runner.py`.
  #
  # Resilience: a window that fails permanently (credit/auth/no structured output)
  # or exhausts its retries ENDS the pass keeping whatever was already collected,
  # and records a warning — the caller degrades rather than aborting.
  class Selection
    Candidate = Data.define(:title, :summary, :start_s, :end_s, :score)

    def initialize(
      llm: Adapters::SelectionLlm.new,
      target_seconds: self.class.default_target_seconds,
      overlap_seconds: self.class.default_overlap_seconds,
      retry_policy: Resilience::RetryPolicy.new
    )
      @llm = llm
      @target = target_seconds
      @overlap = overlap_seconds
      @retry_policy = retry_policy
    end

    def self.default_target_seconds = (ENV["WINDOW_TARGET_SECONDS"].presence || (20 * 60).to_s).to_f
    def self.default_overlap_seconds = (ENV["WINDOW_OVERLAP_SECONDS"].presence || "60").to_f

    # Regenerate a source video's topics from its transcript and return the rows.
    # Returns [] when there is no transcript to analyse.
    def call(source_video, warnings: [])
      transcript = source_video.transcript
      return [] unless transcript

      candidates = extract(transcript.segments, warnings:)
      persist(source_video, candidates)
    end

    # The pure extraction (no persistence): transcript segments -> consolidated
    # Candidate list. Exposed for testing and reuse.
    def extract(segments, warnings: [])
      windows = Windowing.make(segments, target_seconds: @target, overlap_seconds: @overlap)
      resolver = SpanResolver.new(segments)

      raw = []
      windows.each_with_index do |window, i|
        payload = select_window(window, i, windows.size, warnings)
        break if payload == :stop # permanent failure — keep the partial

        coerce_items(payload, "topics").each do |item|
          candidate = build_candidate(item, resolver)
          raw << candidate if candidate
        end
      end
      Consolidate.merge_overlapping(raw)
    end

    private

    def select_window(window, index, total, warnings)
      Resilience.with_retry(policy: @retry_policy, label: "Topics window #{index + 1}") do
        @llm.select(system: TopicPrompts::SYSTEM, user: window.indexed_text, schema: TopicPrompts::SCHEMA)
      end
    rescue StandardError => e # controlled degradation: end the pass, keep the partial
      msg = "Topics: stopped at window #{index + 1}/#{total} — #{e.class}: #{e.message}"
      Rails.logger.warn(msg)
      warnings << msg
      :stop
    end

    def build_candidate(item, resolver)
      start_s, end_s = resolver.resolve(Integer(item.fetch("start_index")), Integer(item.fetch("end_index")))
      Candidate.new(
        title: item.fetch("title").to_s, summary: item["summary"].to_s,
        start_s:, end_s:, score: clamp_score(item["score"])
      )
    rescue KeyError, ArgumentError, TypeError => e
      Rails.logger.warn("Skipping malformed topic #{item.inspect} (#{e.message})")
      nil
    end

    # Tolerant extraction of `payload[key]` as a list of hashes: some models return
    # an indexed dict ({"0" => {...}}) or non-object items; drop only the bad ones.
    def coerce_items(payload, key)
      items = payload.is_a?(Hash) ? payload[key] : nil
      items = items.values if items.is_a?(Hash)
      return [] if items.nil?

      unless items.is_a?(Array)
        Rails.logger.warn("Analysis: field #{key.inspect} is not a list; ignoring.")
        return []
      end
      good = items.select { |it| it.is_a?(Hash) }
      if good.size != items.size
        Rails.logger.warn("Analysis: #{items.size - good.size} item(s) in #{key.inspect} were not objects and were ignored.")
      end
      good
    end

    def clamp_score(value)
      Float(value).clamp(0.0, 1.0)
    rescue ArgumentError, TypeError
      0.0
    end

    # Regeneration replaces the whole set: dropping the old topics cascades their
    # triage and nullifies any cut item that referenced them (a preserved range).
    def persist(source_video, candidates)
      source_video.transaction do
        source_video.topics.destroy_all
        candidates.each_with_index.map do |c, i|
          source_video.topics.create!(
            ordinal: i, title: c.title, summary: c.summary,
            start_s: c.start_s, end_s: c.end_s, score: c.score
          )
        end
      end
    end
  end
end
