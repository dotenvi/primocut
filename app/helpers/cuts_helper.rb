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

  # A clip's render state → its tag. `clip` may be nil (not rendered yet).
  CLIP_STATE_TAG = {
    nil => [ "Not rendered", "bg-card2 text-ink-3 border-line-strong" ],
    "queued" => [ "Queued", "bg-card2 text-ink-2 border-line-strong" ],
    "downloading_section" => [ "Downloading", "bg-accent-bg text-accent border-accent-line" ],
    "aligning" => [ "Aligning", "bg-accent-bg text-accent border-accent-line" ],
    "cutting" => [ "Cutting", "bg-accent-bg text-accent border-accent-line" ],
    "done" => [ "Rendered", "bg-ok-bg text-ok border-ok-line" ],
    "error" => [ "Error", "bg-err-bg text-err border-err-line" ]
  }.freeze

  def clip_state_tag(clip)
    label, klass = CLIP_STATE_TAG.fetch(clip&.state, CLIP_STATE_TAG[nil])
    tag.span(label, class: "tag #{klass}")
  end

  # True while any of the cut's clips is still working (drives the render polling).
  def rendering?(cut)
    cut.status_rendering? || cut.cut_items.any? { |i| i.clip && %w[queued downloading_section aligning cutting].include?(i.clip.state) }
  end

  # An export's state → its tag. `export` may be nil (never exported).
  EXPORT_STATE_TAG = {
    nil => [ "Not exported", "bg-card2 text-ink-3 border-line-strong" ],
    "queued" => [ "Queued", "bg-card2 text-ink-2 border-line-strong" ],
    "packaging" => [ "Packaging", "bg-accent-bg text-accent border-accent-line" ],
    "done" => [ "Ready", "bg-ok-bg text-ok border-ok-line" ],
    "error" => [ "Error", "bg-err-bg text-err border-err-line" ]
  }.freeze

  def export_state_tag(export)
    label, klass = EXPORT_STATE_TAG.fetch(export&.state, EXPORT_STATE_TAG[nil])
    tag.span(label, class: "tag #{klass}")
  end

  # True while the export bundle is still being built (drives the export polling).
  def exporting?(export)
    export && %w[queued packaging].include?(export.state)
  end

  # True while any packaging pass for the cut (or its audience match) is running.
  def packaging_running?(cut)
    CutPackaging.where(cut_id: cut.id, state: "running").exists? ||
      cut.source_video.audience_match&.state_running?
  end
end
