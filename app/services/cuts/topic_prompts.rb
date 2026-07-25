module Cuts
  # Prompt and structured-output schema for the topic selection. Golden rule
  # (technical guideline #2): the LLM NEVER invents timestamps — it receives
  # indexed segments (`[i] M:SS text`) and returns pairs of segment INDICES, which
  # SpanResolver turns into seconds. That is why the schema takes integer
  # start_index/end_index and has no time field. Ported from the PoC
  # `analysis/prompts.py` (as a RubyLLM structured-output schema, not a tool).
  module TopicPrompts
    ANTI_INVENTION =
      "You receive the transcript as numbered lines in the format `[i] M:SS text`, " \
      "where `i` is the segment index. To mark a passage, ALWAYS return the start " \
      "and end segment indices (start_index/end_index) — NEVER invent times nor " \
      "return minute/second numbers. Use only indices that exist in the transcript."

    SYSTEM =
      "You are a podcast/live clip editor working in PT-BR. Your task is to segment " \
      "the transcript into MACRO TOPICS (subjects discussed), in chronological order. " \
      "Create one topic per genuinely distinct subject — do NOT aim for any particular " \
      "number of topics: a short segment may have a few, a long one many. Do not merge " \
      "unrelated subjects to hit a target, nor split a single subject into fragments. " \
      "Each topic has a short title, a 1-sentence summary and a score from 0 to 1 of " \
      "its potential to become a clip.\n#{ANTI_INVENTION}"

    SCHEMA = {
      "type" => "object",
      "properties" => {
        "topics" => {
          "type" => "array",
          "items" => {
            "type" => "object",
            "properties" => {
              "title" => { "type" => "string" },
              "summary" => { "type" => "string" },
              "start_index" => { "type" => "integer" },
              "end_index" => { "type" => "integer" },
              "score" => { "type" => "number" }
            },
            "required" => %w[title summary start_index end_index score]
          }
        }
      },
      "required" => [ "topics" ]
    }.freeze
  end
end
