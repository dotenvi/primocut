require "digest"

module Metrics
  # Syntactic title attributes (deterministic, no LLM). Ported from the PoC
  # `metrics/attributes.py`; only the PURE extraction + content hash live here. The
  # persistence side (`refresh_syntactic_attributes`, an upsert) is a write and
  # belongs to the collection phase, not the read-only metrics slice.
  #
  # The features are extracted with regex/heuristics from the video title and (in the
  # collection phase) stored in `video_attributes` (source="syntactic"), keyed by a
  # content hash of the title so a row is recomputed only when the title changes.
  # These raw attributes feed the per-project conditional distributions in
  # `Metrics::Patterns`; no score is stored here.
  module Attributes
    SOURCE = "syntactic"

    # Any character in the emoji/pictograph ranges — a cheap, dependency-free proxy
    # for emoji in a title (mirrors the PoC's _EMOJI_RE exactly).
    EMOJI_RE = /[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{1F1E6}-\u{1F1FF}\u{2190}-\u{21FF}\u{2B00}-\u{2BFF}]/
    WORD_RE = /[[:alpha:]]+/ # letter-only tokens (Unicode-aware, like Python's re.UNICODE)

    module_function

    # Extract deterministic packaging features from a title.
    def syntactic_attributes(title)
      text = title.to_s
      words = text.scan(WORD_RE)
      caps_words = words.select { |w| w.length >= 2 && w == w.upcase }
      caps_ratio = words.any? ? caps_words.length.to_f / words.length : 0.0
      {
        "length" => text.length,
        "word_count" => words.length,
        "caps_ratio" => caps_ratio.round(4),
        "caps_heavy" => caps_ratio >= 0.5 && words.length >= 2,
        "has_digit" => text.match?(/\d/),
        "has_question" => text.include?("?"),
        "has_exclamation" => text.include?("!"),
        "has_quote" => text.match?(/["“”'‘’]/),
        "has_brackets_or_pipe" => text.match?(/[\[\]()|]/),
        "has_emoji" => text.match?(EMOJI_RE)
      }
    end

    def title_content_hash(title)
      Digest::SHA256.hexdigest(title.to_s)
    end
  end
end
