module ChannelsHelper
  # Registration is idempotent and dedups across projects, so the confirmation
  # says which of the three things actually happened: a new collection, a link to
  # a channel someone already collected, or a link that was already there.
  def tracking_notice(result)
    name = result[:title].presence || result[:channel_id]
    return "Already tracking “#{name}”." unless result[:linked]
    return "Linked “#{name}” — already collected, nothing to re-fetch." if result[:backfill] == "skipped"

    "Added “#{name}” — collecting its uploads now."
  end

  # Detaching keeps every video, snapshot and comment already collected — say so,
  # and say when the channel also stopped being collected because no project
  # tracks it any more.
  def untracking_notice(result)
    return "That channel was not tracked here." unless result[:detached]
    return "Channel detached. Everything collected is kept, and collection stopped." if result[:deactivated]

    "Channel detached. Everything collected is kept."
  end

  # The backfill cell for one tracked channel: a count once collected, live
  # progress while it runs, and the failure otherwise. Ports the PoC Niche
  # screen's backfill column.
  def backfill_cell(row)
    case row.state
    when "done"
      tag.span("#{row.collected} videos", class: "m")
    when "error"
      tag.span("failed", class: "tag bg-err-bg text-err border-err-line", title: row.error)
    else
      return tag.span(row.state, class: "m") unless row.collecting?

      tag.span("#{row.collected}/#{row.expected || '?'}", class: "m text-accent")
    end
  end
end
