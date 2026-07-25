require "digest"
require "set"

module Enrichment
  # Comment synthesis: the content hash, the indexed prompt, quote resolution and
  # the project-level aggregation of what the audience asked for. Ported from the
  # PoC `metrics/comments.py`. Two rules shape it:
  #
  # - **The model never writes a quote.** The comments reach it indexed (`[i]`) and
  #   it answers with `example_index`; `resolve_example` maps the index back to the
  #   stored comment and CLAMPS it, so a model that invents an index still cannot
  #   invent audience words.
  # - **The aggregation is code, not a second LLM pass.** `request_key` normalises
  #   the spelling so two videos asking for the same guest merge, and the ranking is
  #   plain counting — auditable, re-tunable, and free.
  #
  # The result is persisted in `video_enrichments` (kind `comment_synthesis`), not
  # `video_attributes`: a narrative synthesis has no business being counted as a
  # packaging pattern by `Metrics::Patterns`.
  module Comments
    KIND = "comment_synthesis".freeze

    # Per-comment cap in the prompt — the tail is rarely the point, and this bounds
    # the token spend of a pass paid for only once.
    PROMPT_COMMENT_MAX_CHARS = 500
    TOP_REQUESTS_PER_TYPE = 20
    REQUEST_TYPES = %w[guest topic format other].freeze
    SENTIMENTS = %w[positive mixed negative neutral].freeze

    module_function

    # SHA-256 over the comment SET (sorted by id so the digest ignores the order the
    # API returned; the like count is included so a re-collection that only reshuffles
    # the ranking still counts as new content worth re-reading).
    def content_hash(comments)
      parts = comments.map { |c| "#{c.comment_id}:#{c.like_count}:#{c.text}" }.sort
      Digest::SHA256.hexdigest(parts.join("\n"))
    end

    def build_user_prompt(title, comments)
      "Video title: #{title}\n\nTop comments (#{comments.size}), most liked first:\n#{format_comments(comments)}"
    end

    # Index the comments for the model: `[i] (N likes) text`, most-liked first.
    def format_comments(comments)
      comments.each_with_index.map do |c, i|
        text = c.text.to_s.gsub(/\s+/, " ").strip[0, PROMPT_COMMENT_MAX_CHARS]
        "[#{i}] (#{c.like_count} likes) #{text}"
      end.join("\n")
    end

    # Resolve a model-returned index into a real stored comment. Out-of-range or
    # non-integer indices are CLAMPED, not rejected — every displayed quote must be
    # text the audience actually wrote, and a clamped neighbour is honest.
    def resolve_example(comments, index)
      return {} if comments.empty?

      i = (Integer(index, exception: false) || 0).clamp(0, comments.size - 1)
      c = comments[i]
      { "comment_id" => c.comment_id, "text" => c.text, "like_count" => c.like_count, "author" => c.author }
    end

    # Normalise a requested name/subject so spelling variants merge. In code (not the
    # prompt) so the aggregation can be re-tuned without re-paying for a synthesis.
    def request_key(value)
      text = value.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "") # strip combining marks
      text.downcase.gsub(/[^[:word:]\s]/, " ").gsub(/\s+/, " ").strip
    end

    # The persisted payload: the model's observations with every index resolved.
    # Read defensively — a sloppy or partial response thins the payload rather than
    # breaking the row.
    def build_payload(raw, comments)
      themes = Array(raw["themes"]).select { |t| t.is_a?(Hash) }.map do |t|
        { "theme" => t["theme"].to_s.strip, "mentions" => to_int(t["mentions"]), "example" => resolve_example(comments, t["example_index"]) }
      end

      requests = Array(raw["requests"]).select { |r| r.is_a?(Hash) }.filter_map do |r|
        value = r["value"].to_s.strip
        next if value.empty?

        { "type" => REQUEST_TYPES.include?(r["type"]) ? r["type"] : "other", "value" => value,
          "value_key" => request_key(value), "mentions" => to_int(r["mentions"]), "example" => resolve_example(comments, r["example_index"]) }
      end

      { "themes" => themes, "requests" => requests,
        "sentiment" => SENTIMENTS.include?(raw["sentiment"]) ? raw["sentiment"] : "neutral",
        "sentiment_note" => raw["sentiment_note"].to_s.strip, "comments_analysed" => comments.size }
    end

    # Merge the audience requests of a project's syntheses, grouped by type. `items`
    # is [[video_id, payload], ...]; requests merge on `request_key`, and the reported
    # `value` is the most common raw spelling behind that key. Ranked by the number of
    # VIDEOS asking (a niche signal), then by total mentions (one fandom).
    def aggregate_requests(items)
      acc = Hash.new { |h, k| h[k] = { videos: Set.new, mentions: 0, spellings: Hash.new(0) } }
      videos = Set.new

      items.each do |video_id, payload|
        videos << video_id
        Array((payload || {})["requests"]).each do |r|
          next unless r.is_a?(Hash)

          value = r["value"].to_s.strip
          next if value.empty?

          type = REQUEST_TYPES.include?(r["type"]) ? r["type"] : "other"
          entry = acc[[ type, r["value_key"].presence || request_key(value) ]]
          entry[:videos] << video_id
          entry[:mentions] += to_int(r["mentions"])
          entry[:spellings][value] += 1
        end
      end

      by_type = REQUEST_TYPES.to_h { |t| [ t, [] ] }
      acc.each do |(type, _key), entry|
        by_type[type] << {
          "value" => entry[:spellings].max_by { |spelling, count| [ count, -spelling.length ] }.first,
          "videos" => entry[:videos].size, "mentions" => entry[:mentions], "video_ids" => entry[:videos].to_a.sort
        }
      end
      by_type.each do |type, rows|
        by_type[type] = rows.sort_by { |r| [ -r["videos"], -r["mentions"], r["value"] ] }.first(TOP_REQUESTS_PER_TYPE)
      end

      { "videos_synthesised" => videos.size, "by_type" => by_type }
    end

    def to_int(value) = Integer(value, exception: false) || 0
  end
end
