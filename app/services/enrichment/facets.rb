module Enrichment
  # Boolean facets derived from the model's raw output, in code (not asked of the
  # model), so the thresholds stay auditable and tunable without re-paying for the
  # analysis. `Metrics::Patterns` only counts booleans, so these facets are what
  # reaches the conditional distributions. Ported from the PoC `metrics/enrichment.py`
  # (`derive_title_facets`); thumbnail facets arrive with that kind's slice.
  module Facets
    TONES = %w[neutral hype outrage humor curiosity drama informative].freeze

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
  end
end
