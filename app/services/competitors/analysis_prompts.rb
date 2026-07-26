module Competitors
  # System prompts + JSON schemas for the opt-in analysis kinds. Written in plain
  # JSON Schema (fed straight to `with_schema`); ported from the PoC
  # `analysis/enrichment_prompts.py`. `title`, `thumbnail` (vision) and the
  # `comments` synthesis.
  module AnalysisPrompts
    COMMENT_SYNTHESIS_SYSTEM = <<~SYS.strip.freeze
      You read the top comments of a YouTube video for a clip editor studying the demand \
      in a niche. Report only what the comments actually say. A request counts only when a \
      comment explicitly asks for it — never infer a wish from enthusiasm, and never turn a \
      compliment into a request. The comments are usually in PT-BR: keep themes and requested \
      names in the comments' own language. Quote nothing: to point at a comment, give its \
      index [i]. If there are no requests, return an empty list rather than a plausible-looking one.
    SYS

    COMMENT_SYNTHESIS_SCHEMA = {
      "type" => "object",
      "additionalProperties" => false,
      "properties" => {
        "themes" => {
          "type" => "array",
          "maxItems" => 8,
          "description" => "Recurring subjects in the comments, most discussed first.",
          "items" => {
            "type" => "object",
            "additionalProperties" => false,
            "properties" => {
              "theme" => { "type" => "string", "description" => "The recurring subject, in the comments' own language." },
              "mentions" => { "type" => "integer", "description" => "How many of the supplied comments express it." },
              "example_index" => { "type" => "integer", "description" => "The index [i] of one supplied comment that expresses it. Never write the comment's text." }
            },
            "required" => %w[theme mentions example_index]
          }
        },
        "requests" => {
          "type" => "array",
          "maxItems" => 10,
          "description" => "Things the audience explicitly asks for. Only what a comment actually asks for — never an inferred wish.",
          "items" => {
            "type" => "object",
            "additionalProperties" => false,
            "properties" => {
              "type" => {
                "type" => "string",
                "enum" => %w[guest topic format other],
                "description" => "guest = a person to bring on, topic = a subject to cover, format = how to make it (length, editing, series), other = anything else asked for."
              },
              "value" => { "type" => "string", "description" => "The thing asked for, named as the audience names it." },
              "mentions" => { "type" => "integer", "description" => "How many of the supplied comments ask for it." },
              "example_index" => { "type" => "integer", "description" => "The index [i] of one supplied comment asking for it. Never write the comment's text." }
            },
            "required" => %w[type value mentions example_index]
          }
        },
        "sentiment" => { "type" => "string", "enum" => %w[positive mixed negative neutral], "description" => "The overall reaction across the supplied comments." },
        "sentiment_note" => { "type" => "string", "description" => "One short sentence on the overall reaction." }
      },
      "required" => %w[themes requests sentiment sentiment_note]
    }.freeze

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
