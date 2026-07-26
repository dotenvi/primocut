module SourcesHelper
  # Status → tag colours, using the design system's semantic tokens: in-flight is
  # accent, done is ok (green), error is err (red), the rest neutral.
  SOURCE_STATUS_TAG = {
    "queued" => "bg-card2 text-ink-2 border-line-strong",
    "downloading" => "bg-accent-bg text-accent border-accent-line",
    "transcribing" => "bg-accent-bg text-accent border-accent-line",
    "analyzing" => "bg-accent-bg text-accent border-accent-line",
    "done" => "bg-ok-bg text-ok border-ok-line",
    "error" => "bg-err-bg text-err border-err-line",
    "stopped" => "bg-card2 text-ink-2 border-line-strong"
  }.freeze

  def source_status_tag(source_video)
    klass = SOURCE_STATUS_TAG.fetch(source_video.status, "bg-card2 text-ink-2 border-line-strong")
    tag.span(source_video.status.humanize, class: "tag #{klass}")
  end

  # Re-submitting a link the project already holds re-runs it instead of creating
  # a second row, so the confirmation says which of the two happened.
  def submitted_notice(video)
    return "Re-processing “#{source_label(video)}”." if video.pipeline_jobs.any?

    "Submitted for processing."
  end

  def rerun_notice(video) = "Re-processing “#{source_label(video)}”."

  def source_label(video) = video.title.presence || video.youtube_id

  # Per-state chip for the pipeline log, kept in lock-step with Pipeline::Steps'
  # state vocabulary so the rail and the log can never disagree.
  STEP_STATUS = {
    "done" => { word: "complete", text: "text-ok", ring: "bg-ok text-white", glyph: "✓" },
    "failed" => { word: "failed", text: "text-err", ring: "bg-err text-white", glyph: "✕" },
    "running" => { word: "processing", text: "text-accent", ring: "bg-accent text-accent-on animate-pulse", glyph: "" },
    "pending" => { word: "queued", text: "text-ink-3", ring: "border border-line", glyph: "" },
    "empty" => { word: "ignored", text: "text-ink-3", ring: "bg-line-strong", glyph: "" },
    "skipped" => { word: "skipped", text: "text-ink-3", ring: "border border-dashed border-line-strong text-ink-3", glyph: "/" }
  }.freeze

  def step_status(state) = STEP_STATUS.fetch(state, STEP_STATUS["pending"])

  # The lamp colour on the rail, for the same six states.
  STEP_LAMP = {
    "done" => "bg-ok",
    "running" => "bg-accent shadow-[0_0_0_3px_var(--color-accent-bg)]",
    "failed" => "bg-err"
  }.freeze

  def step_lamp(state) = STEP_LAMP.fetch(state, "")

  # A step's duration, in the shortest form that still reads: "8s", "2m 14s".
  # "—" when the run predates timestamped stage history.
  def step_duration(seconds)
    return "—" if seconds.nil?

    total = seconds.round
    return "#{total}s" if total < 60

    "#{total / 60}m #{(total % 60).to_s.rjust(2, "0")}s"
  end

  # The line under the pipeline bar: what the run is doing, or why it stopped.
  def source_progress_note(row)
    return row.job&.error.presence || "Failed" if row.failed?
    return "" unless row.active?

    "#{row.job&.stage.presence || 'Queued'} · #{row.job&.progress.to_i}%"
  end
end
