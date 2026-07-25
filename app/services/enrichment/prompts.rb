module Enrichment
  # System prompts + JSON schemas for the opt-in enrichment kinds. Written in plain
  # JSON Schema (fed straight to `with_schema`); ported from the PoC
  # `analysis/enrichment_prompts.py`. Only the `title` kind lives here today —
  # `thumbnail` (vision) and `comments` (synthesis) arrive in later slices.
  module Prompts
    TITLE_SYSTEM = <<~SYS.strip.freeze
      You analyse YouTube video titles for a clip editor studying what works in a niche. \
      The titles are usually in PT-BR. Report only what the title itself says — do not \
      speculate about the video's content. When an attribute is absent, return the empty \
      value (an empty list or an empty string) rather than a plausible-looking guess.
    SYS

    TITLE_SCHEMA = {
      "type" => "object",
      "additionalProperties" => false,
      "properties" => {
        "person_names" => {
          "type" => "array",
          "items" => { "type" => "string" },
          "description" => "Names of real people named in the title, exactly as written. Empty list when the title names nobody."
        },
        "topic" => {
          "type" => "string",
          "description" => "The subject of the video in at most 4 words, in the title's own language."
        },
        "tone" => {
          "type" => "string",
          "enum" => %w[neutral hype outrage humor curiosity drama informative],
          "description" => "The dominant tone of the title."
        },
        "quoted_speech" => {
          "type" => "string",
          "description" => "The line of speech the title quotes, verbatim. Empty string when the title quotes nobody."
        }
      },
      "required" => %w[person_names topic tone quoted_speech]
    }.freeze
  end
end
