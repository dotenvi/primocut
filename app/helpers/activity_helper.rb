module ActivityHelper
  # The log spans days but a row only shows its clock time, so the days are named
  # once as separators rather than repeated on every row.
  def day_label(time)
    case time.to_date
    when Date.current then "Today"
    when Date.yesterday then "Yesterday"
    else time.strftime("%a · %Y-%m-%d")
    end
  end

  # What the log row was ABOUT: the subject it names, falling back to the payload's
  # own scope word (a cycle event has no subject — it names "recent" or "full").
  def activity_scope(row)
    row.video&.title.presence || row.source_video&.title.presence ||
      row.channel_title || row.payload["scope"].presence || "—"
  end

  # The quota an event accounted for. "—" (muted) for the events that spend none,
  # which is most of them — only the cycle records units.
  def activity_quota(row)
    row.payload["quota_units"]
  end

  # An event failed only while it is unresolved: a failure that was retried and
  # closed is history, not an open problem. The label names the stage when the
  # payload knows it.
  def activity_failed?(row)
    row.event.severity_error? && row.event.resolved_at.nil?
  end

  def activity_result_tag(row)
    if activity_failed?(row)
      tag.span(row.payload["stage"].presence || "failed", class: "tag bg-err-bg text-err border-err-line")
    else
      tag.span("ok", class: "tag bg-ok-bg text-ok border-ok-line")
    end
  end
end
