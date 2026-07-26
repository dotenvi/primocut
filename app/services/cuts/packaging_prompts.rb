module Cuts
  # Prompts and structured-output schemas for the opt-in AI packaging of a cut.
  # Ported from the PoC `analysis/packaging_prompts.py` (as RubyLLM structured-output
  # schemas, not Anthropic tools). The prompt builders turn a
  # `Metrics::PackagingContext` (the source video's project patterns, under three
  # lenses) plus the clip's own content into readable text. Every measured pattern
  # carries a short id the model echoes back, so a citation the code cannot match is
  # dropped, never invented — the never-invent rule applied to patterns, the way
  # SpanResolver applies it to timestamps. Frame ranking returns a frame INDEX,
  # resolved to a real extracted frame in code.
  module PackagingPrompts
    module_function

    TITLES_SYSTEM =
      "You are a title strategist for a YouTube clip channel in a specific niche. You " \
      "propose titles for ONE clip, in PT-BR, grounded ONLY in the measured niche " \
      "patterns you are given. Every title must cite which measured patterns it applies, " \
      "by the pattern id shown — never cite a pattern that is not in the list, and never " \
      "claim a differential the niche does not have. When the niche is flat (no " \
      "differentials), do not invent one: lean on the subject and on the value that " \
      "carries (a name, a quoted line), and say so plainly. Keep titles tight and " \
      "specific to THIS clip's content."

    BRIEF_SYSTEM =
      "You write a thumbnail BRIEF for one YouTube clip — a specification for a human " \
      "designer, NOT an image and NOT a prompt for an image generator. Ground every " \
      "recommendation in the measured niche patterns you are given, and reference the " \
      "real outlier examples by their video id. When the niche is flat, say honestly that " \
      "packaging is not the lever here and keep the brief minimal, emphasising the " \
      "subject and the value that carries. Never invent a pattern the niche lacks."

    FRAME_RANK_SYSTEM =
      "You rank candidate thumbnail frames extracted from a clip against a thumbnail " \
      "brief. Judge expression strength, sharpness and framing. Refer to each frame ONLY " \
      "by its index [i] — never describe it as a file. Return a score for every frame you " \
      "are shown and name the single best index."

    AUDIENCE_SYSTEM =
      "You match a niche's audience requests to a live's topics. A request matches a topic " \
      "only when the topic genuinely delivers what the audience explicitly asked for — " \
      "never a loose thematic overlap. Refer to a topic ONLY by its topic_id, and echo a " \
      "request's value exactly as given. Return an empty list when nothing matches."

    def titles_schema(count)
      {
        "type" => "object",
        "properties" => {
          "titles" => {
            "type" => "array", "minItems" => count, "maxItems" => count,
            "items" => {
              "type" => "object",
              "properties" => {
                "title" => { "type" => "string" },
                "length_chars" => { "type" => "integer" },
                "patterns_applied" => {
                  "type" => "array",
                  "items" => {
                    "type" => "object",
                    "properties" => {
                      "kind" => { "type" => "string", "enum" => %w[differential convention carries_value] },
                      "reference" => { "type" => "string" }
                    },
                    "required" => %w[kind reference]
                  }
                },
                "rationale" => { "type" => "string" }
              },
              "required" => %w[title length_chars patterns_applied rationale]
            }
          }
        },
        "required" => [ "titles" ]
      }
    end

    BRIEF_SCHEMA = {
      "type" => "object",
      "properties" => {
        "composition" => {
          "type" => "object",
          "properties" => {
            "face_count" => { "type" => "integer" },
            "expression" => { "type" => "string", "enum" => %w[neutral happy shock anger sadness fear disgust] },
            "framing" => { "type" => "string", "enum" => %w[single confrontation reaction object] }
          },
          "required" => %w[face_count expression framing]
        },
        "text" => {
          "type" => "object",
          "properties" => {
            "word_count" => { "type" => "integer" },
            "suggestion" => { "type" => "string" }
          },
          "required" => %w[word_count suggestion]
        },
        "colors" => {
          "type" => "object",
          "properties" => {
            "palette" => { "type" => "array", "maxItems" => 3,
                           "items" => { "type" => "string", "enum" => %w[red orange yellow green blue purple pink brown black white gray] } },
            "contrast" => { "type" => "string", "enum" => %w[low medium high] }
          },
          "required" => %w[palette contrast]
        },
        "graphics" => {
          "type" => "object",
          "properties" => {
            "arrow" => { "type" => "boolean" },
            "circle_highlight" => { "type" => "boolean" },
            "note" => { "type" => "string" }
          },
          "required" => %w[arrow circle_highlight note]
        },
        "references" => {
          "type" => "array",
          "items" => { "type" => "object",
                       "properties" => { "video_id" => { "type" => "string" }, "why" => { "type" => "string" } },
                       "required" => %w[video_id why] }
        },
        "pattern_notes" => { "type" => "string" }
      },
      "required" => %w[composition text colors graphics references pattern_notes]
    }.freeze

    FRAME_RANK_SCHEMA = {
      "type" => "object",
      "properties" => {
        "rankings" => {
          "type" => "array",
          "items" => {
            "type" => "object",
            "properties" => {
              "frame" => { "type" => "integer" }, "score" => { "type" => "number" },
              "expression" => { "type" => "number" }, "sharpness" => { "type" => "number" },
              "framing" => { "type" => "number" }, "fits_brief" => { "type" => "boolean" },
              "note" => { "type" => "string" }
            },
            "required" => %w[frame score expression sharpness framing fits_brief note]
          }
        },
        "best_frame" => { "type" => "integer" }
      },
      "required" => %w[rankings best_frame]
    }.freeze

    AUDIENCE_SCHEMA = {
      "type" => "object",
      "properties" => {
        "matches" => {
          "type" => "array",
          "items" => {
            "type" => "object",
            "properties" => {
              "topic_id" => { "type" => "integer" },
              "request_type" => { "type" => "string", "enum" => %w[guest topic format other] },
              "request_value" => { "type" => "string" },
              "confidence" => { "type" => "string", "enum" => %w[strong weak] }
            },
            "required" => %w[topic_id request_type request_value confidence]
          }
        }
      },
      "required" => [ "matches" ]
    }.freeze

    # A short, stable id (`D#`/`C#`/`V#`) for every measured pattern in the context.
    # The same map renders the prompt AND validates the model's citations, so a
    # `reference` resolves exactly when it names a real measured pattern.
    def pattern_index(context)
      out = {}
      Array(context[:differential]).each_with_index { |d, i| out["D#{i + 1}"] = d.merge(kind: "differential") }
      Array(context[:conventions]).each_with_index { |c, i| out["C#{i + 1}"] = c.merge(kind: "convention") }
      i = 1
      (context[:carries_value] || {}).each do |field, rows|
        Array(rows).each do |r|
          out["V#{i}"] = r.merge(kind: "carries_value", field: field)
          i += 1
        end
      end
      out
    end

    def build_titles_prompt(clip, context, count, ids)
      join_sections([
        render_niche(context), render_clip(clip), render_patterns(ids), render_examples(context),
        "Propose exactly #{count} titles for the clip. Each must cite which measured " \
        "patterns it applies, by the id shown (e.g. D1, C2, V1)."
      ])
    end

    def build_brief_prompt(clip, context, ids)
      join_sections([
        render_niche(context), render_clip(clip), render_patterns(ids), render_examples(context),
        "Write one thumbnail brief for the clip. Ground it in the measured patterns and " \
        "reference the real outlier examples by video id."
      ])
    end

    def build_audience_prompt(topics, requests)
      tlines = [ "LIVE TOPICS (match by topic_id):" ]
      topics.each { |t| tlines << "  [#{t[:id]}] #{t[:title]}#{t[:summary].present? ? " — #{t[:summary]}" : ''}" }
      rlines = [ "NICHE AUDIENCE REQUESTS:" ]
      requests.each { |r| rlines << "  (#{r[:type]}) #{r[:value]} — asked by #{r[:videos]} video(s)" }
      join_sections([ tlines.join("\n"), rlines.join("\n"),
                      "Return every topic that genuinely delivers an explicitly requested thing." ])
    end

    def frame_rank_prompt(count, brief)
      "Thumbnail brief:\n#{brief_summary(brief)}\n\nRank the #{count} candidate frames [0..#{count - 1}] against the brief."
    end

    # -- renderers --

    def render_niche(context)
      n = context[:niche]
      flat = context[:flat] ? " — FLAT niche: packaging is not the lever here" : ""
      "NICHE: #{n[:project_name]} (#{n[:channels]} competitor channel(s), #{n[:outliers]} #{n[:format]} outlier(s))#{flat}"
    end

    def render_clip(clip)
      lines = [ "CLIP TO PACKAGE: #{clip[:title].inspect}" ]
      lines << "  summary: #{clip[:summary]}" if clip[:summary].present?
      excerpt = clip[:transcript_excerpt].to_s.strip
      lines << "  transcript excerpt:\n#{excerpt}" if excerpt.present?
      lines.join("\n")
    end

    def render_patterns(ids)
      diffs = ids.select { |_k, v| v[:kind] == "differential" }
      convs = ids.select { |_k, v| v[:kind] == "convention" }
      vals = ids.select { |_k, v| v[:kind] == "carries_value" }
      lines = []
      lines << "DIFFERENTIALS (what separates outliers from the rest):"
      if diffs.any?
        diffs.each do |k, v|
          lift = v[:lift] ? format("%.1fx", v[:lift]) : "n/a"
          lines << "  [#{k}] #{v[:attribute]} (#{v[:source]}) — #{v[:verdict]}, lift #{lift}: " \
                   "#{pct(v[:freq_outlier])} of outliers vs #{pct(v[:freq_control])} of the rest"
        end
      else
        lines << "  (none — this niche is flat on packaging; do not invent one)"
      end
      lines << "CONVENTIONS (what the niche requires — table-stakes, not a lever):"
      convs.any? ? convs.each { |k, v| lines << "  [#{k}] #{v[:attribute]} (#{v[:source]}) — #{pct(v[:freq])} of the niche (n=#{v[:n]})" } : (lines << "  (none measured)")
      lines << "CARRIES VALUE (specific values that carry views in this niche):"
      if vals.any?
        vals.each do |k, v|
          lift = v[:lift] ? format("%.1fx", v[:lift]) : "unique to outliers"
          lines << "  [#{k}] #{v[:field]}: #{v[:value].inspect} — #{v[:videos_outlier]} outlier(s) vs #{v[:videos_control]} other(s), #{lift}"
        end
      else
        lines << "  (none measured)"
      end
      lines.join("\n")
    end

    def render_examples(context)
      examples = Array(context[:examples])
      return "REAL OUTLIER EXAMPLES: (none analyzed yet)" if examples.empty?

      lines = [ "REAL OUTLIER EXAMPLES (real titles/attributes — cite by video id):" ]
      examples.each do |ex|
        mult = ex[:median_multiple] ? format("%.1fx median", ex[:median_multiple]) : ""
        lines << "  [#{ex[:video_id]}] #{mult} — #{ex[:title].inspect}"
        ta = ex[:title_attrs] || {}
        names = Array(ta["person_names"]).join(", ")
        lines << "      names: #{names}" if names.present?
        quoted = ta["quoted_speech"].to_s.strip
        lines << "      quote: #{quoted.inspect}" if quoted.present?
      end
      lines.join("\n")
    end

    def brief_summary(brief)
      return "(no brief generated — judge on general thumbnail quality)" if brief.blank?

      comp = brief["composition"] || {}
      text = brief["text"] || {}
      "faces=#{comp['face_count']}, expression=#{comp['expression']}, framing=#{comp['framing']}, " \
        "text≈#{text['word_count']} words (#{text['suggestion'].to_s.inspect})"
    end

    def pct(fraction) = format("%.0f%%", fraction.to_f * 100)
    def join_sections(sections) = sections.join("\n\n")
  end
end
