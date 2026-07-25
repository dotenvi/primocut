module Enrichment
  # System prompts + JSON schemas for the opt-in enrichment kinds. Written in plain
  # JSON Schema (fed straight to `with_schema`); ported from the PoC
  # `analysis/enrichment_prompts.py`. `title` and `thumbnail` (vision) live here;
  # the `comments` synthesis arrives in a later slice.
  module Prompts
    THUMBNAIL_SYSTEM = <<~SYS.strip.freeze
      You analyse YouTube thumbnails for a clip editor studying what works in a niche. \
      Report only what is actually visible in the image — never guess at the video's \
      content, and never infer from what you think the video is about. If an attribute \
      does not apply, use the neutral/empty value (0, false, "none" or an empty string) \
      rather than a plausible-looking one.
    SYS

    THUMBNAIL_SCHEMA = {
      "type" => "object",
      "additionalProperties" => false,
      "properties" => {
        "face_count" => { "type" => "integer", "description" => "Number of clearly visible human faces. 0 if none." },
        "dominant_expression" => {
          "type" => "string",
          "enum" => %w[none neutral happy shock anger sadness fear disgust],
          "description" => "Facial expression of the most prominent face. Use 'none' when there is no visible face."
        },
        "has_text" => { "type" => "boolean", "description" => "Whether any text is overlaid on the image." },
        "text_word_count" => { "type" => "integer", "description" => "Number of words of overlaid text. 0 when there is none." },
        "text" => { "type" => "string", "description" => "The overlaid text transcribed verbatim, preserving its casing. Empty string when there is no text." },
        "dominant_colors" => {
          "type" => "array",
          "maxItems" => 3,
          "items" => { "type" => "string", "enum" => %w[red orange yellow green blue purple pink brown black white gray] },
          "description" => "Up to 3 dominant colors, most dominant first."
        },
        "contrast" => { "type" => "string", "enum" => %w[low medium high], "description" => "Overall visual contrast between the subject and the background." },
        "has_arrow" => { "type" => "boolean", "description" => "Whether an arrow graphic points at something." },
        "has_circle_or_highlight" => { "type" => "boolean", "description" => "Whether a circle, ring or highlight is drawn to call out part of the image." },
        "is_confrontation_framing" => { "type" => "boolean", "description" => "Whether two or more subjects are framed against each other (face-to-face, split screen, versus)." }
      },
      "required" => %w[face_count dominant_expression has_text text_word_count text dominant_colors contrast has_arrow has_circle_or_highlight is_confrontation_framing]
    }.freeze

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
