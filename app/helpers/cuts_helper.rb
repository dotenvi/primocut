module CutsHelper
  # A topic's triage opinion → the tag colours: kept ("maybe") reads as accent,
  # discarded is muted, open is neutral. `triage` is the TopicTriage or nil.
  def triage_tag(triage)
    case triage&.state
    when "maybe"
      tag.span("Kept", class: "tag bg-accent-bg text-accent border-accent-line")
    when "discarded"
      tag.span("Discarded", class: "tag bg-card2 text-ink-3 border-line-strong")
    else
      tag.span("Open", class: "tag bg-card2 text-ink-2 border-line-strong")
    end
  end

  # A topic's clip-potential score (0..1) as a compact percent label.
  def topic_score_label(topic)
    "#{(topic.score.to_f * 100).round}%"
  end

  # Seconds as H:MM:SS / M:SS — the same clock the export manifest renders.
  def clock(seconds)
    Cuts::Manifest.format_timestamp(seconds)
  end
end
