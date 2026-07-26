# View formatting for the metrics dashboards. Ported from the PoC `lib/format.js`
# so the numbers read identically (compact counts, percentages with Wilson
# intervals, multipliers, VPH). Presentation only — no business logic.
module MetricsHelper
  # Weekday labels in the cadence chart's order (Monday = 0, matching Core#cadence).
  WEEKDAYS = %w[Mon Tue Wed Thu Fri Sat Sun].freeze

  def youtube_watch_url(youtube_video_id)
    "https://www.youtube.com/watch?v=#{youtube_video_id}"
  end

  # Short date (YYYY-MM-DD) from an ISO string. "" for nil/blank.
  def short_date(iso)
    return "" if iso.blank?

    Time.iso8601(iso).utc.strftime("%Y-%m-%d")
  rescue ArgumentError
    ""
  end

  # Clock time (HH:MM) for a log row, in the app's zone. "" for nil.
  def hhmm(time)
    time&.strftime("%H:%M").to_s
  end

  # The histogram bucket index a view count falls into, given the bucket edges, or
  # nil when it cannot be placed. Used to mark a video on the channel spread strip.
  def spread_bucket_index(views, edges)
    return nil if views.nil? || edges.blank? || edges.length < 2

    idx = edges.each_cons(2).find_index { |lo, hi| views >= lo && views < hi }
    idx || (views >= edges.last ? edges.length - 2 : nil)
  end

  # Compact count: 1234 -> "1.2k", 3_400_000 -> "3.4M". "—" for nil.
  def compact_number(n)
    return "—" if n.nil?

    abs = n.abs
    if abs >= 1e9 then "#{trim_zero(n / 1e9)}B"
    elsif abs >= 1e6 then "#{trim_zero(n / 1e6)}M"
    elsif abs >= 1e3 then "#{trim_zero(n / 1e3)}k"
    else n.round.to_s
    end
  end

  # A 0..1 rate as a percentage: 0.042 -> "4.2%". "—" for nil.
  def pct(rate)
    return "—" if rate.nil?

    "#{trim_zero(rate * 100)}%"
  end

  # Views-per-hour: 1234 -> "1.2k/h". "—" for nil.
  def vph_label(vph)
    return "—" if vph.nil?

    "#{compact_number(vph)}/h"
  end

  # Multiplier for outlier scores / ratios: 8.23 -> "8.2×". "—" for nil.
  def multiplier(x)
    return "—" if x.nil?

    "#{format('%.1f', x)}×"
  end

  # A 0..1 proportion with its [lo, hi] interval: (0.78, [0.55, 0.93]) ->
  # "78% [55–93%]". Shows the interval so a wide (small-sample) one is visible.
  def pct_ci(freq, ci)
    return "—" if freq.nil?
    return pct(freq) if ci.nil?

    "#{pct(freq)} [#{(ci[0] * 100).round}–#{(ci[1] * 100).round}%]"
  end

  # The band tag for an outlier row (a payload hash): "p99" under the percentile
  # basis, else the ordinal band. "" when the video reached no band.
  def band_tag(row)
    return "" if row[:band].nil?

    row[:percentile] ? "p#{plain_number(row[:percentile])}" : row[:band]
  end

  # The full band label with its evidence: "p99 exceptional" (percentile basis) or
  # the ordinal band alone. "" when no band was reached.
  def band_full(row)
    return "" if row[:band].nil?

    row[:percentile] ? "p#{plain_number(row[:percentile])} #{row[:band]}" : row[:band]
  end

  # Render an attribute value for the packaging-features list.
  def fmt_attr_value(value)
    case value
    when true then "✓"
    when false then "✗"
    when Array then value.any? ? value.join(", ") : "—"
    else value == "" ? "—" : value.to_s
    end
  end

  # Lift emphasis: a real positive lift glows, everything else stays muted.
  def lift_class(lift)
    lift && lift >= 1.05 ? "text-heat-99" : "text-ink-3"
  end

  private

  # "%.1f" with a trailing ".0" stripped, matching JS toFixed(1).replace(/\.0$/,'').
  def trim_zero(x)
    format("%.1f", x).sub(/\.0$/, "")
  end

  # Whole floats render without a decimal (99.0 -> "99").
  def plain_number(x)
    (x % 1).zero? ? x.to_i.to_s : x.to_s
  end
end
