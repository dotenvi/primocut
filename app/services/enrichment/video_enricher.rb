module Enrichment
  # Opt-in AI enrichment of one competitor video's `kind` (costs an LLM call).
  # NEVER runs on a schedule — only from an explicit user action. Every result is
  # keyed by a **content hash** so it is paid for once and shared across every
  # project that tracks the channel: a re-run whose content is unchanged is a free
  # cache hit. Per kind: `title` → SHA-256 of the title; `thumbnail` → the byte hash
  # the snapshot cycle already maintains (so the cache gate costs no network — bytes
  # are fetched only once the hash says the work is due); `comments` → SHA-256 of the
  # collected comment set. Ported from the PoC `metrics/enrichment.py`. See
  # [[Adapters::SelectionLlm]] and [[Enrichment::Comments]].
  #
  # The packaging kinds store raw output + code-derived [[Enrichment::Facets]] in
  # `video_attributes`; the comment synthesis lands in `video_enrichments` (a
  # narrative, not a packaging pattern). Resilience: a per-video failure is logged,
  # recorded on the row as `state: "error"` with the message the UI renders, and the
  # content hash is cleared so the next explicit click retries. Only an unknown
  # `kind` or a misused `regenerate` raises (a caller bug, not a per-video failure).
  class VideoEnricher
    # kind → the storage key its result is written under. Grows per slice.
    KINDS = { "title" => "title_llm", "thumbnail" => "thumbnail_llm", "comments" => Comments::KIND }.freeze

    class UnknownKind < ArgumentError; end
    class RegenerateNotAllowed < ArgumentError; end
    # The content cannot be hashed yet (a thumbnail whose bytes never downloaded, a
    # video whose comments were never collected), so there is nothing to key the
    # cache on — refuse rather than recharge every click.
    class NotEnrichable < StandardError; end

    Plan = Data.define(:kind, :source, :content_hash, :title, :thumbnail_url, :comments)

    # A comments `regenerate` re-fetches the thread from the API before planning, so
    # the refreshed set changes the content hash and the cache gate lets the pass
    # through. Lazily built so no client/key is needed unless regenerate is used.
    DEFAULT_RECOLLECTOR = ->(video) { Competitors::CommentCollection.new(client: Adapters::YoutubeApi.from_env).collect_video(video) }

    def initialize(llm: Adapters::SelectionLlm.new, thumbnail_fetcher: Thumbnails.method(:fetch_bytes), comment_recollector: nil)
      @llm = llm
      @thumbnail_fetcher = thumbnail_fetcher
      @comment_recollector = comment_recollector || DEFAULT_RECOLLECTOR
    end

    # Enrich one video, skipping whatever the cache covers. Returns :enriched,
    # :cached, or :failed. Never raises for a per-video failure.
    def call(youtube_video_id, kind: "title", regenerate: false)
      source = source_for(kind)
      raise RegenerateNotAllowed, "regenerate applies only to the 'comments' kind, not #{kind.inspect}" if regenerate && kind != "comments"

      video = CompetitorVideo.find_by(youtube_video_id:)
      if video.nil?
        Rails.logger.error("enrichment: unknown video #{youtube_video_id.inspect}")
        return :failed
      end

      @comment_recollector.call(video) if regenerate
      plan = plan_for(video, kind, source)
      return :cached if plan.nil?

      mark_running(video, source)
      save(video, plan, run(plan))
      :enriched
    rescue UnknownKind, RegenerateNotAllowed
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

    def synthesis?(source) = source == Comments::KIND

    # A due plan, or nil when the cache already covers the current content.
    def plan_for(video, kind, source)
      comments = kind == "comments" ? load_comments(video) : []
      content_hash = content_hash_for(video, kind, comments)
      existing = existing_row(video, source)
      return nil if existing&.state_done? && existing.content_hash.present? && existing.content_hash == content_hash

      Plan.new(kind:, source:, content_hash:, title: video.title, thumbnail_url: video.thumbnail_url, comments:)
    end

    def content_hash_for(video, kind, comments)
      case kind
      when "title"
        Metrics::Attributes.title_content_hash(video.title)
      when "thumbnail"
        video.thumbnail_hash.presence ||
          raise(NotEnrichable, "thumbnail bytes have not been hashed for this video yet — run a snapshot cycle first")
      when "comments"
        Comments.content_hash(comments)
      end
    end

    # Most-liked first (the model reads them ranked); refuse when there is nothing to
    # synthesise, saying why so the UI can render the reason verbatim.
    def load_comments(video)
      comments = video.video_comments.order(like_count: :desc, comment_id: :asc).to_a
      raise NotEnrichable, no_comments_reason(video) if comments.empty?

      comments
    end

    def no_comments_reason(video)
      case video.comments_state
      when "disabled" then "comments are disabled on this video, so there is nothing to synthesise"
      when "error" then "the last comment collection failed (#{video.comments_error}) — it is retried on the next snapshot cycle"
      when "done" then "this video has no comments, so there is nothing to synthesise"
      else "no comments have been collected for this video yet — they are collected automatically once it becomes a definitive outlier"
      end
    end

    # The paid call. Network only — no transaction held.
    def run(plan)
      case plan.kind
      when "title"
        @llm.select(system: Prompts::TITLE_SYSTEM, user: "Video title: #{plan.title}", schema: Prompts::TITLE_SCHEMA)
      when "thumbnail"
        @llm.select(
          system: Prompts::THUMBNAIL_SYSTEM, user: "Analyse this YouTube thumbnail.",
          schema: Prompts::THUMBNAIL_SCHEMA, image: @thumbnail_fetcher.call(plan.thumbnail_url)
        )
      when "comments"
        @llm.select(
          system: Prompts::COMMENT_SYNTHESIS_SYSTEM, user: Comments.build_user_prompt(plan.title, plan.comments),
          schema: Prompts::COMMENT_SYNTHESIS_SCHEMA
        )
      end
    end

    def save(video, plan, raw)
      if synthesis?(plan.source)
        row_for(video, plan.source).update!(payload: Comments.build_payload(raw, plan.comments), content_hash: plan.content_hash, state: "done", error: "")
      else
        row_for(video, plan.source).update!(attrs: raw.merge(facets_for(plan.kind, raw)), content_hash: plan.content_hash, state: "done", error: "")
      end
    end

    def facets_for(kind, raw)
      kind == "title" ? Facets.title(raw) : Facets.thumbnail(raw)
    end

    def existing_row(video, source)
      synthesis?(source) ? video.video_enrichments.find_by(kind: source) : video.video_attributes.find_by(source:)
    end

    def row_for(video, source)
      synthesis?(source) ? video.video_enrichments.find_or_initialize_by(kind: source) : video.video_attributes.find_or_initialize_by(source:)
    end

    def mark_running(video, source)
      row_for(video, source).update!(state: "running")
    end

    # Record a visible failure and clear the hash so the next click retries this
    # video rather than treating the failure as cached.
    def mark_error(video, source, message)
      row_for(video, source).update!(state: "error", error: message, content_hash: "")
    rescue StandardError => e # a video we cannot even flag must not abort the batch
      Rails.logger.error("enrichment: could not record the failure of #{video.youtube_video_id}: #{e.message}")
    end
  end
end
