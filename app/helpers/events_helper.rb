# Presentation mapping for the Radar / Activity event rows. Ported from the PoC
# `lib/events.js` so the feed reads identically: band colours follow the heat
# scale (p99 > p97 > p90), non-band niche events get their own hue (packaging =
# violet, resurgence = accent), ops failures read red.
module EventsHelper
  # `text` is the full label on a tall card, `abbr` the short one on a compact row.
  EventTag = Struct.new(:text, :abbr, :css, keyword_init: true)

  BAND_TAGS = {
    "exceptional" => { abbr: "p99", css: "bg-heat-bg99 text-heat-99 border-heat-ln99" },
    "strong" => { abbr: "p97", css: "bg-heat-bg97 text-heat-97 border-heat-ln97" },
    "relevant" => { abbr: "p90", css: "bg-heat-bg90 text-heat-90 border-heat-ln90" }
  }.freeze

  NEUTRAL_TAG = "bg-card2 text-ink-2 border-line-strong".freeze

  # The coloured tag for an event: band-scaled for a crossing, hued per type
  # otherwise. Anything unknown degrades to the humanised type in neutral.
  def event_tag(row)
    payload = row.payload

    case row.event_type
    when "outlier_crossed"
      band = BAND_TAGS[payload["band"]] || BAND_TAGS["relevant"]
      suffix = payload["provisional"] ? "provisional" : payload["band"]
      EventTag.new(text: "#{band[:abbr]} #{suffix}".strip, abbr: band[:abbr], css: band[:css])
    when "packaging_changed"
      EventTag.new(text: "packaging", abbr: "pkg", css: "bg-viol-bg text-viol border-viol-line")
    when "resurgence"
      EventTag.new(text: "resurgence", abbr: "↑", css: "bg-accent-bg text-accent border-accent-line")
    else
      label = row.event_type.tr("_", " ")
      css = row.event.severity_error? ? "bg-err-bg text-err border-err-line" : NEUTRAL_TAG
      EventTag.new(text: label, abbr: label, css: css)
    end
  end

  # The one-line metric under a card title. "" when the payload says nothing worth
  # a line — the card then shows only its title and badges.
  def event_meta(row)
    payload = row.payload

    case row.event_type
    when "outlier_crossed"
      parts = []
      parts << "#{compact_number(payload['views'])} views" if payload["views"]
      parts << "#{multiplier(payload['median_multiple'])} median" if payload["median_multiple"]
      parts << "provisional" if payload["provisional"]
      parts.join(" · ")
    when "packaging_changed"
      "#{payload['field'].presence || 'packaging'} changed"
    when "resurgence"
      payload["ratio"] ? "#{multiplier(payload['ratio'])} its recent average" : ""
    else
      payload["message"].presence || payload["detail"].presence || ""
    end
  end
end
