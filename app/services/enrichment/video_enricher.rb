module Enrichment
  # Opt-in AI enrichment of one competitor video's `kind` (costs an LLM call).
  # NEVER runs on a schedule — only from an explicit user action. Every result is
  # keyed by a **content hash** (title kind → SHA-256 of the title), so it is paid
  # for once and shared across every project that tracks the channel: a re-run whose
  # content is unchanged is a free cache hit. Ported from the PoC
  # `metrics/enrichment.py` — the `title` kind; `thumbnail` (vision) and `comments`
  # (synthesis) arrive in later slices. See [[Adapters::SelectionLlm]].
  #
  # The raw model output is stored in `video_attributes` (source `title_llm`) merged
  # with the boolean [[Enrichment::Facets]] derived in code. Resilience: a per-video
  # failure is logged, recorded on the row as `state: "error"` with the message the
  # UI renders, and the content hash is cleared so the next explicit click retries.
  # Only an unknown `kind` raises (a caller bug, not a per-video failure).
  class VideoEnricher
    # kind → the `video_attributes.source` its result is stored under. Grows per slice.
    KINDS = { "title" => "title_llm" }.freeze

    class UnknownKind < ArgumentError; end

    Plan = Data.define(:source, :content_hash, :title)

    def initialize(llm: Adapters::SelectionLlm.new)
      @llm = llm
    end

    # Enrich one video, skipping whatever the cache covers. Returns :enriched,
    # :cached, or :failed. Never raises for a per-video failure.
    def call(youtube_video_id, kind: "title")
      source = source_for(kind)
      video = CompetitorVideo.find_by(youtube_video_id:)
      if video.nil?
        Rails.logger.error("enrichment: unknown video #{youtube_video_id.inspect}")
        return :failed
      end

      plan = plan_for(video, source)
      return :cached if plan.nil?

      mark_running(video, source)
      raw = @llm.select(system: Prompts::TITLE_SYSTEM, user: "Video title: #{plan.title}", schema: Prompts::TITLE_SCHEMA)
      save(video, plan, raw)
      :enriched
    rescue UnknownKind
      raise
    rescue StandardError => e
      Rails.logger.error("enrichment: video #{youtube_video_id} (#{kind}) failed: #{e.message}")
      mark_error(video, source, e.message) if video
      :failed
    end

    private

    def source_for(kind)
      KINDS.fetch(kind) { raise UnknownKind, "unknown enrichment kind: #{kind.inspect} (use #{KINDS.keys.inspect})" }
    end

    # A due plan, or nil when the cache already covers the current title.
    def plan_for(video, source)
      content_hash = Metrics::Attributes.title_content_hash(video.title)
      existing = video.video_attributes.find_by(source:)
      return nil if existing&.state_done? && existing.content_hash.present? && existing.content_hash == content_hash

      Plan.new(source:, content_hash:, title: video.title)
    end

    def mark_running(video, source)
      video.video_attributes.find_or_initialize_by(source:).update!(state: "running")
    end

    def save(video, plan, raw)
      video.video_attributes.find_or_initialize_by(source: plan.source).update!(
        attrs: raw.merge(Facets.title(raw)), content_hash: plan.content_hash, state: "done", error: ""
      )
    end

    # Record a visible failure and clear the hash so the next click retries this
    # video rather than treating the failure as cached.
    def mark_error(video, source, message)
      video.video_attributes.find_or_initialize_by(source:).update!(state: "error", error: message, content_hash: "")
    rescue StandardError => e # a video we cannot even flag must not abort the batch
      Rails.logger.error("enrichment: could not record the failure of #{video.youtube_video_id}: #{e.message}")
    end
  end
end
