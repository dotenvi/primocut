module Enrichment
  # Boolean facets derived from the model's raw output, in code (not asked of the
  # model), so the thresholds stay auditable and tunable without re-paying for the
  # analysis. `Metrics::Patterns` only counts booleans, so these facets are what
  # reaches the conditional distributions. The enums are one-hot expanded in full
  # (not just the observed value) so the reported attribute set does not depend on
  # which videos happen to be enriched. Ported from the PoC `metrics/enrichment.py`.
  module Facets
    TONES = %w[neutral hype outrage humor curiosity drama informative].freeze
    EXPRESSIONS = %w[none neutral happy shock anger sadness fear disgust].freeze
    COLORS = %w[red orange yellow green blue purple pink brown black white gray].freeze
    MULTIPLE_FACES = 2
    TEXT_HEAVY_WORDS = 4

    module_function

    def title(raw)
      names = Array(raw["person_names"]).select { |n| n.is_a?(String) && n.strip.present? }
      tone = raw["tone"].presence || "neutral"

      facets = {
        "title_has_person_name" => names.length >= 1,
        "title_multiple_people" => names.length >= 2,
        "title_has_quoted_speech" => raw["quoted_speech"].to_s.strip.present?
      }
      TONES.each { |t| facets["title_tone_#{t}"] = (tone == t) }
      facets
    end

    def thumbnail(raw)
      faces = raw["face_count"].to_i
      words = raw["text_word_count"].to_i
      expression = raw["dominant_expression"].presence || "none"
      colors = Array(raw["dominant_colors"]).select { |c| c.is_a?(String) }.to_set

      facets = {
        "thumb_has_face" => faces >= 1,
        "thumb_multiple_faces" => faces >= MULTIPLE_FACES,
        "thumb_has_text" => raw["has_text"] == true,
        "thumb_text_heavy" => words >= TEXT_HEAVY_WORDS,
        "thumb_high_contrast" => raw["contrast"] == "high",
        "thumb_has_arrow" => raw["has_arrow"] == true,
        "thumb_has_circle" => raw["has_circle_or_highlight"] == true,
        "thumb_confrontation" => raw["is_confrontation_framing"] == true
      }
      EXPRESSIONS.each { |e| facets["thumb_expression_#{e}"] = (expression == e) }
      COLORS.each { |c| facets["thumb_color_#{c}"] = colors.include?(c) }
      facets
    end
  end
end
