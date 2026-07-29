module CutsHelper
  # The line under the render control. Before anything is rendered it says what
  # rendering does; afterwards it reports what came out, because the clips are
  # deliverables and nothing removes them for you.
  def render_note(items)
    clips = items.filter_map(&:clip)
    rendered = clips.count(&:state_done?)
    failed = clips.count(&:state_error?)
    if rendered.zero?
      "Renders in the background (NVENC, exact cuts) — keep deciding while clips are produced. " \
        "Each item becomes its own MP4."
    else
      "#{rendered} of #{items.size} rendered#{" · #{failed} failed" if failed.positive?}. " \
        "Clips are deliverables — nothing is cleaned up automatically."
    end
  end

  # The label of a control whose work happens in the background: while it runs it
  # says so, in the gerund, with the ellipsis that means "still going". One place,
  # so the room's three long actions cannot drift into three different dialects.
  def busy_label(working, idle, busy)
    working ? "#{busy}…" : idle
  end

  # ---- render telemetry ----

  # Bytes as the size a person reads off a file listing.
  def bytes_label(bytes)
    return nil unless bytes.to_i.positive?

    mb = bytes / 1_048_576.0
    mb >= 1024 ? "#{(mb / 1024).round(2)} GB" : "#{mb.round(1)} MB"
  end

  # Seconds of wall time, compact: a render item is minutes, not hours.
  def secs_label(seconds)
    return nil unless seconds.to_f.positive?

    s = seconds.round
    s < 60 ? "#{s}s" : "#{s / 60}m#{format('%02ds', s % 60)}"
  end

  # Real seconds spent per second of media produced. The honest unit of render cost:
  # a 20s item and a 5min item are not comparable in raw seconds.
  def ratio_label(ratio)
    ratio ? "#{number_with_precision(ratio, precision: 2)}×" : nil
  end

  def bitrate_label(bits_per_s)
    bits_per_s ? "#{(bits_per_s / 1_000_000.0).round(1)} Mb/s" : nil
  end

  # The one line that answers "how much longer" — always marked as an estimate,
  # because it is the measured rate applied to what is left, not a promise.
  def eta_label(render)
    seconds = render.eta_s or return nil

    "~#{secs_label(seconds)} left"
  end

  # A clip's telemetry, as the short mono line under its title. Nil when there is
  # nothing measured yet, so the row stays quiet until it has something to say.
  def clip_metrics(row)
    if row.done
      [ secs_label(row.wall_s), ratio_label(row.ratio), bytes_label(row.bytes) ].compact.join(" · ")
    elsif row.working
      [ secs_label(row.wall_s), "elapsed" ].compact.join(" ").presence
    end
  end

  # Why the preview is not available yet. It plays the rendered clips, so it needs
  # all of them — the count is the useful part while a render is in flight.
  def preview_disabled_reason(room)
    return "Add items to the cut, then render it to preview." if room.items.empty?

    "Render the cut to preview it — #{room.rendered_items.size} of #{room.items.size} clips rendered."
  end

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
