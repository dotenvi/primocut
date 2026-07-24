# View formatting for the metrics dashboards. Ported from the PoC `lib/format.js`
# so the numbers read identically (compact counts, percentages with Wilson
# intervals, multipliers, VPH). Presentation only — no business logic.
module MetricsHelper
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
