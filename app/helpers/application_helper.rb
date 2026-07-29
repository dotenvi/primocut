module ApplicationHelper
  # Width policy, ported from the PoC `App.svelte`: the canvas is generous by
  # default so large screens get used, and only reading or table-oriented screens
  # opt back into the comfortable measure — long prose and wide tables read worse
  # when they sprawl.
  #
  # Sources is deliberately absent from this list. It keeps its own comfortable
  # measure while the pipeline panel is closed and gives it up when the panel
  # opens, so the table and the panel fit on one line; that decision belongs to
  # the screen, not here.
  READING_SCREENS = %w[radar activity niche videos channels settings].freeze

  def content_width
    READING_SCREENS.include?(controller_name) ? "max-w-[1160px]" : "max-w-[1680px]"
  end

  # The sparkle — the four-pointed star the industry converged on for "this hands
  # your work to a model" (Gemini, Copilot, Notion, and every icon set's `sparkles`).
  # A button that spends tokens says so before it is clicked, and it says it in a
  # glyph rather than in a colour, because colour is already carrying hierarchy.
  #
  # Inline and drawn in `currentColor`: it inherits whatever the button is doing —
  # accent, hover, and the 50% of a disabled control — and costs no request.
  # Two stars, not one: the big one low and left, a small one riding above its
  # shoulder. That pairing is what makes the glyph read as "sparkle" instead of as
  # a star or an asterisk, and it is the arrangement the prototype used.
  # Three stars — the big one carrying the glyph, a middling one over its shoulder and
  # a small one under its arm. The sizes are staged rather than drawn to scale: below
  # roughly a third of the box a concave star rasterises to a blob at this size, and a
  # blob among stars reads as a defect. Control points sit close to each centre so the
  # arms stay thin and the waist survives the rounding.
  def ai_icon(size: 14)
    tag.svg(width: size, height: size, viewBox: "0 0 24 24", fill: "currentColor",
            class: "shrink-0", aria_hidden: "true") do
      safe_join([
        tag.path(d: "M9 6 Q10 13 17 14 Q10 15 9 22 Q8 15 1 14 Q8 13 9 6 Z"),
        tag.path(d: "M17.5 0.5 Q18.1 5.4 23 6 Q18.1 6.6 17.5 11.5 Q16.9 6.6 12 6 Q16.9 5.4 17.5 0.5 Z"),
        tag.path(d: "M19.5 14 Q19.95 17.55 23.5 18 Q19.95 18.45 19.5 22 Q19.05 18.45 15.5 18 Q19.05 17.55 19.5 14 Z")
      ])
    end
  end
end
