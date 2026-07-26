require "pathname"

module Cuts
  # Orchestration for the opt-in AI packaging of a cut (guideline 9 — every action
  # is triggered ONLY by an explicit user action). Ported from the PoC
  # `worker/packaging_jobs.py`. The cache gate + persistence live here; the pure
  # passes live in `Cuts::Packaging`. Four actions:
  #
  # - generate(kind: title/thumb_brief): one LLM pass per clip, grounded in the
  #   source video's project patterns (Metrics::PackagingContext). Per-item
  #   isolation + a pay-once content-hash cache.
  # - extract_frames: DETERMINISTIC candidate-frame extraction (FFmpeg only, no LLM),
  #   pay-once by presence.
  # - rank_frames: the SEPARATE, opt-in vision pass scoring the extracted frames
  #   against the brief.
  # - match_audience: the cheap, cached-per-source-video semantic match of the
  #   niche's audience requests to the topics; empty (no LLM) when there is no demand.
  LLM_KINDS = %w[title thumb_brief].freeze

  class PackagingService
    Result = Data.define(:kind, :generated, :skipped, :failed)

    def initialize(
      llm: Adapters::SelectionLlm.new,
      ffmpeg: Adapters::Ffmpeg.new,
      clips_dir: Cuts::Render.default_clips_dir,
      titles_k: (ENV["PACKAGING_TITLES_K"].presence || "5").to_i,
      frames_per_clip: (ENV["PACKAGING_FRAMES_PER_CLIP"].presence || "3").to_i,
      scene_threshold: (ENV["PACKAGING_SCENE_THRESHOLD"].presence || "0.30").to_f,
      context_builder: ->(project) { Metrics::PackagingContext.new(project).call },
      audience_requests: ->(project) { Competitors::AudienceRequests.new(project).call }
    )
      @llm = llm
      @ffmpeg = ffmpeg
      @clips_root = Pathname(clips_dir)
      @titles_k = titles_k
      @frames_per_clip = frames_per_clip
      @scene_threshold = scene_threshold
      @context_builder = context_builder
      @audience_requests = audience_requests
    end

    # Generate `title`/`thumb_brief` for a cut's items, per-item isolated + cached.
    def generate(cut, kind:, item_ids: nil, regenerate: false)
      raise ArgumentError, "unknown packaging kind: #{kind.inspect}" unless LLM_KINDS.include?(kind)

      context = @context_builder.call(cut.source_video.project)
      count = kind == "title" ? @titles_k : 0
      generated = skipped = failed = 0

      each_item(cut, item_ids) do |item, clip|
        chash = Packaging.content_hash(kind, clip, context, k: count)
        existing = CutPackaging.find_by(cut_item_id: item.id, kind:)
        if !regenerate && existing&.state_done? && existing.content_hash == chash
          skipped += 1
          next
        end

        upsert(item, cut, kind:, payload: {}, content_hash: chash, state: "running")
        payload = kind == "title" ? Packaging.generate_titles(clip, context, @titles_k, llm: @llm) : Packaging.generate_brief(clip, context, llm: @llm)
        upsert(item, cut, kind:, payload:, content_hash: chash, state: "done")
        generated += 1
      rescue StandardError => e # per-item isolation
        failed += 1
        record_failure(kind, item, cut, e)
      end

      Result.new(kind:, generated:, skipped:, failed:)
    end

    # Extract candidate frames for a cut's rendered items — FFmpeg only, no LLM.
    def extract_frames(cut, item_ids: nil, regenerate: false)
      extracted = failed = 0
      rendered_items(cut, item_ids).each do |item, clip|
        @ffmpeg.extract_frames(
          @clips_root.join(clip.rel_path), frames_dir_for(cut, item.position),
          count: @frames_per_clip, scene_threshold: @scene_threshold, regenerate:
        )
        extracted += 1
      rescue StandardError => e # per-item isolation
        failed += 1
        Rails.logger.error("frames: item #{item.id} of cut #{cut.id} failed: #{e.message}")
      end
      Result.new(kind: "frames", generated: extracted, skipped: 0, failed:)
    end

    # Rank each item's extracted frames against its brief (opt-in vision pass).
    def rank_frames(cut, item_ids: nil)
      ranked = skipped = failed = 0
      each_cut_item(cut, item_ids) do |item|
        dir = frames_dir_for(cut, item.position)
        names = Pathname.glob(dir.join("frame-*.jpg")).sort.map { |p| p.basename.to_s }
        if names.empty?
          skipped += 1 # nothing extracted for this item yet
          next
        end

        upsert(item, cut, kind: "frame_ranking", payload: {}, state: "running")
        brief = CutPackaging.find_by(cut_item_id: item.id, kind: "thumb_brief")&.payload
        images = names.map { |name| dir.join(name).binread }
        payload = Packaging.rank_frames(names, brief, images, llm: @llm)
        upsert(item, cut, kind: "frame_ranking", payload:, state: "done")
        ranked += 1
      rescue StandardError => e # per-item isolation
        failed += 1
        record_failure("frame_ranking", item, cut, e)
      end
      Result.new(kind: "frame_ranking", generated: ranked, skipped:, failed:)
    end

    # Match the niche's audience requests to the source video's topics, cached per
    # source video (the key folds the topics AND the request set).
    def match_audience(source_video, regenerate: false)
      topics = source_video.topics.ordered.map { |t| { id: t.id, title: t.title, summary: t.summary } }
      requests = audience_requests(source_video.project)
      chash = Packaging.stable("topics" => topics.map { |t| [ t[:id], t[:title] ] },
                               "requests" => requests.map { |r| [ r[:type], r[:value] ] })
      chash = Digest::SHA256.hexdigest(chash)

      existing = source_video.audience_match
      return existing if !regenerate && existing&.state_done? && existing.content_hash == chash

      match = source_video.audience_match || source_video.build_audience_match
      match.update!(payload: {}, content_hash: "", state: "running", error: "")
      payload = Packaging.match_audience(topics, requests, llm: @llm)
      match.update!(payload:, content_hash: chash, state: "done", error: "")
      match
    rescue StandardError => e
      source_video.audience_match&.update!(state: "error", error: e.message)
      raise
    end

    private

    # Yield (item, clip_content_hash) for the requested items.
    def each_item(cut, item_ids)
      segments = cut.source_video.transcript&.segments || []
      scope(cut, item_ids).each { |item| yield item, clip_content(item, segments) }
    end

    def each_cut_item(cut, item_ids)
      scope(cut, item_ids).each { |item| yield item }
    end

    # Yield (item, clip) only for items with a `done` clip on disk.
    def rendered_items(cut, item_ids)
      scope(cut, item_ids).filter_map do |item|
        clip = item.clip
        [ item, clip ] if clip&.state_done? && clip.rel_path.present?
      end
    end

    def scope(cut, item_ids)
      items = cut.cut_items.order(:position).includes(:clip, :topic)
      item_ids ? items.where(id: item_ids) : items
    end

    # Title/summary/transcript excerpt for one cut item (topic or manual range).
    def clip_content(item, segments)
      topic = item.topic
      { title: topic&.title || "Manual range", summary: topic&.summary.to_s,
        transcript_excerpt: excerpt(segments, item.start_s, item.end_s) }
    end

    # The transcript text overlapping [start, end], truncated to `limit` chars.
    def excerpt(segments, start, finish, limit: 1200)
      parts = []
      segments.each do |seg|
        s = seg["start"].to_f
        e = seg["end"].to_f
        text = seg["text"].to_s.strip
        next if e <= start || s >= finish || text.empty?

        parts << text
        break if parts.sum(&:length) >= limit
      end
      parts.join(" ")[0, limit].to_s
    end

    def audience_requests(project)
      agg = @audience_requests.call(project)
      (agg["by_type"] || {}).flat_map do |type, rows|
        Array(rows).map { |r| { type:, value: r["value"], videos: r["videos"] } }
      end
    end

    def frames_dir_for(cut, position)
      @clips_root.join(cut.source_video.youtube_id, cut.id.to_s, "frames", format("%03d", position))
    end

    def upsert(item, cut, kind:, payload:, content_hash: "", state: "done", error: "")
      row = CutPackaging.find_or_initialize_by(cut_item_id: item.id, kind:)
      row.update!(cut_id: cut.id, payload:, content_hash:, state:, error:)
      row
    end

    def record_failure(kind, item, cut, error)
      Rails.logger.error("packaging(#{kind}): item #{item.id} of cut #{cut.id} failed: #{error.message}")
      CutPackaging.find_by(cut_item_id: item.id, kind:)&.update!(state: "error", error: error.message)
    rescue StandardError => e
      Rails.logger.error("packaging(#{kind}): could not record failure of #{item.id}: #{e.message}")
    end
  end
end
