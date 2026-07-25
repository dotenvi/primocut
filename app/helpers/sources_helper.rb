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
end
