require "json"
require "digest"

module Cuts
  # Pure LLM passes for the opt-in AI packaging (no DB; the model is the only side
  # effect). Each builds a prompt from a `Metrics::PackagingContext` + the clip's
  # content, forces the matching structured schema, and VALIDATES the answer against
  # what was measured before returning it (the never-invent rule). Ported from the
  # PoC `packaging/generate.py`. The cache gate + persistence live in
  # `Cuts::PackagingService`, the same split `Enrichment::VideoEnricher` uses.
  module Packaging
    module_function

    # -- content hashing (pay-once keys) --

    def content_hash(kind, clip, context, k: 0)
      raw = stable(
        "kind" => kind, "k" => k,
        "clip" => { "title" => clip[:title].to_s, "summary" => clip[:summary].to_s, "excerpt" => clip[:transcript_excerpt].to_s },
        "patterns" => patterns_fingerprint(context)
      )
      Digest::SHA256.hexdigest(raw)
    end

    # Only the measured signal — not volatile metadata — so a generation is reused
    # while the niche patterns are unchanged and recomputed when they move.
    def patterns_fingerprint(context)
      stable(
        "differential" => context[:differential],
        "conventions" => context[:conventions],
        "carries_value" => context[:carries_value],
        "examples" => Array(context[:examples]).map { |e| e[:video_id] },
        "flat" => !!context[:flat]
      )
    end

    # -- titles --

    def generate_titles(clip, context, count, llm:, model: nil)
      ids = PackagingPrompts.pattern_index(context)
      raw = llm.select(
        system: PackagingPrompts::TITLES_SYSTEM,
        user: PackagingPrompts.build_titles_prompt(clip, context, count, ids),
        schema: PackagingPrompts.titles_schema(count), model:
      )
      { "titles" => clean_titles(raw["titles"] || [], ids, count), "flat" => !!context[:flat] }
    end

    # Keep at most `count` titles; drop citations that name no measured pattern, and
    # recompute length_chars in code (never trusted from the model).
    def clean_titles(raw_titles, ids, count)
      raw_titles.first(count).filter_map do |t|
        next unless t.is_a?(Hash)

        title = t["title"].to_s.strip
        next if title.empty?

        applied = Array(t["patterns_applied"]).filter_map do |c|
          ref = c.is_a?(Hash) ? c["reference"] : nil
          { "kind" => ids[ref][:kind], "reference" => ref } if ids.key?(ref)
        end
        { "title" => title, "length_chars" => title.length, "patterns_applied" => applied,
          "rationale" => t["rationale"].to_s.strip }
      end
    end

    # -- thumbnail brief --

    def generate_brief(clip, context, llm:, model: nil)
      ids = PackagingPrompts.pattern_index(context)
      raw = llm.select(
        system: PackagingPrompts::BRIEF_SYSTEM,
        user: PackagingPrompts.build_brief_prompt(clip, context, ids),
        schema: PackagingPrompts::BRIEF_SCHEMA, model:
      )
      # Clamp references to real outlier examples — the model cannot cite a video the
      # niche never surfaced.
      example_ids = Array(context[:examples]).map { |e| e[:video_id] }.to_set
      raw["references"] = Array(raw["references"]).select { |r| r.is_a?(Hash) && example_ids.include?(r["video_id"]) }
      raw["flat"] = !!context[:flat]
      raw
    end

    # -- frame ranking (opt-in, vision) --

    def rank_frames(frame_names, brief, images, llm:, model: nil)
      n = frame_names.size
      raw = llm.select(
        system: PackagingPrompts::FRAME_RANK_SYSTEM,
        user: PackagingPrompts.frame_rank_prompt(n, brief),
        schema: PackagingPrompts::FRAME_RANK_SCHEMA, images:, model:
      )
      rankings = Array(raw["rankings"]).filter_map do |r|
        idx = clamp_index(r["frame"], n)
        next if idx.nil?

        { "frame" => idx, "filename" => frame_names[idx], "score" => r["score"].to_f,
          "expression" => r["expression"].to_f, "sharpness" => r["sharpness"].to_f,
          "framing" => r["framing"].to_f, "fits_brief" => !!r["fits_brief"], "note" => r["note"].to_s }
      end
      best = clamp_index(raw["best_frame"], n)
      best ||= rankings.max_by { |r| r["score"] }&.fetch("frame") || 0
      { "rankings" => rankings, "best_frame" => best, "best_filename" => n.zero? ? "" : frame_names[best] }
    end

    # -- audience match (cheap, cached per source video) --

    def match_audience(topics, requests, llm:, model: nil)
      return {} if requests.empty? || topics.empty? # silent degradation — no LLM cost

      real_ids = topics.map { |t| t[:id].to_i }.to_set
      raw = llm.select(
        system: PackagingPrompts::AUDIENCE_SYSTEM,
        user: PackagingPrompts.build_audience_prompt(topics, requests),
        schema: PackagingPrompts::AUDIENCE_SCHEMA, model:
      )
      out = Hash.new { |h, k| h[k] = [] }
      Array(raw["matches"]).each do |m|
        tid = Integer(m["topic_id"], exception: false)
        next if tid.nil? || !real_ids.include?(tid)

        out[tid] << { "type" => m["request_type"] || "other", "value" => m["request_value"].to_s.strip,
                      "confidence" => m["confidence"] || "weak" }
      end
      out.transform_keys(&:to_s)
    end

    # -- helpers --

    def clamp_index(value, size)
      idx = Integer(value, exception: false)
      return nil if idx.nil? || size.zero?

      idx.clamp(0, size - 1)
    end

    # Stable JSON (recursively sorted keys) so a fingerprint is order-independent.
    def stable(obj)
      JSON.generate(deep_sort(obj))
    end

    def deep_sort(obj)
      case obj
      when Hash then obj.map { |k, v| [ k.to_s, deep_sort(v) ] }.sort_by(&:first).to_h
      when Array then obj.map { |v| deep_sort(v) }
      else obj
      end
    end
  end
end
