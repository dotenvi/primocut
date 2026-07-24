module Metrics
  # Pure numeric core of the metrics engine (no DB, no I/O). Ported verbatim from
  # the PoC `metrics/core.py`. The rationale comments are preserved on purpose
  # (AGENTS.md §2.4): they encode methodology decisions that would otherwise be
  # re-litigated —
  #
  # - baselines use the **median**, never the mean, so a single viral in the window
  #   does not distort the channel's typical performance;
  # - Shorts and long-form are scored against **separate** baselines (the caller
  #   passes the same-format peer set);
  # - views-per-hour comes **exclusively from snapshot deltas** — when no delta
  #   exists the value is `nil`, never `total_views / age`;
  # - a young video's score is flagged **provisional**, and a channel with too few
  #   same-format videos yields **insufficient_sample** rather than a misleading number.
  module Core
    # Band names in ascending severity. A video's band is the highest one whose
    # threshold it reaches; the three names mean the same thing in either basis
    # (percentile or fixed-multiple) — see `band_ruler`.
    BAND_NAMES = %w[relevant strong exceptional].freeze

    # Number of bars in the "channel spread" strip. Fixed so the same distribution
    # renders identically wherever it appears (Radar card, video detail).
    SPREAD_BUCKETS = 28

    # ------------------------- small value types -------------------------

    # One point of a video's view time series.
    Snap = Data.define(:captured_at, :views)

    # Metadata used for the descriptive cadence/engagement aggregates.
    VideoMeta = Data.define(:published_at, :is_short, :duration_s)

    # The per-channel, per-format ruler that classifies a video into a band.
    # `median`/`sample_size` describe the rolling-window peer set. `basis` is
    # "percentile" or "fixed_multiple"; `cutoffs` maps each band name to its ruler
    # value (percentiles 90/97/99, or multiples 3/6/10). `thresholds` maps each band
    # name to the ABSOLUTE view count a video must reach for that band.
    BandRuler = Data.define(:median, :sample_size, :basis, :cutoffs, :thresholds)

    # `median_multiple` (views / median) stays readable ("20.6× the median") but no
    # longer classifies; `band` is the ordinal verdict. `percentile` is the cutoff
    # percentile of the reached band (percentile basis only), `nil` in the legacy
    # fixed-multiple basis. `band_cutoffs` travels alongside so a consumer (e.g. the
    # event log) is self-descriptive: a later config change cannot retroactively
    # rewrite the meaning of a recorded band.
    OutlierScore = Data.define(
      :median_multiple, :band, :percentile, :band_basis, :band_cutoffs,
      :provisional, :baseline, :sample_size, :status
    )

    VphPoint = Data.define(:from_at, :to_at, :hours, :vph)
    Resurgence = Data.define(:is_resurgent, :ratio, :current_vph, :recent_avg_vph)
    Impact = Data.define(:vph_before, :vph_after)
    Engagement = Data.define(:like_rate, :comment_rate)
    Cadence = Data.define(:uploads_per_week, :by_weekday, :by_hour, :duration_by_format)

    # A view-count histogram of a channel-format window: `counts[i]` peers fall in
    # `[edges[i], edges[i+1])`. `edges` has `len(counts) + 1` entries spanning
    # `[0, max]`. `n` is the window size; `min`/`max` the observed view range.
    SpreadHistogram = Data.define(:counts, :edges, :min, :max, :n)

    module_function

    # ------------------------- helpers -------------------------

    # Median of a non-empty sequence (nil if empty). Robust to outliers — this is
    # why baselines never use the mean. Matches Python's statistics.median: for an
    # even count it averages the two middle values.
    def median(values)
      vals = values.compact.map(&:to_f).sort
      return nil if vals.empty?

      mid = vals.length / 2
      if vals.length.odd?
        vals[mid]
      else
        (vals[mid - 1] + vals[mid]) / 2.0
      end
    end

    # Parse three ascending, comma-separated cutoffs into the band map. Percentile
    # basis expects "90,97,99"; fixed-multiple expects "3,6,10". The three values are
    # sorted and zipped onto (relevant, strong, exceptional).
    def parse_cutoffs(spec)
      vals = spec.split(",").filter_map { |part| part.strip.empty? ? nil : part.to_f }.sort
      unless vals.length == BAND_NAMES.length
        raise ArgumentError, "expected #{BAND_NAMES.length} cutoffs, got #{spec.inspect}"
      end
      BAND_NAMES.zip(vals).to_h
    end

    # The q-th percentile (q in 0..100) by the nearest-rank method — the value at
    # 1-based rank ceil(q/100 · n), no interpolation. `nil` for an empty input.
    #
    # Nearest-rank (rather than linear interpolation) is deliberate: with the small
    # samples we work with (>= 10), interpolation would invent cutoffs strictly
    # between two observed view counts — values no real video in the window ever had
    # — whereas nearest-rank always returns an actually-observed data point and is
    # stable and deterministic as the window shifts by one video.
    def nearest_rank_percentile(values, q)
      vals = values.compact.map(&:to_f).sort
      return nil if vals.empty?

      rank = ((q / 100.0) * vals.length).ceil
      rank = rank.clamp(1, vals.length)
      vals[rank - 1]
    end

    # Bucket a window's view counts into `buckets` equal-width bars over `[0, max]`.
    #
    # Linear over `[0, max]` (not `[min, max]`) on purpose: the story a channel
    # spread tells is exactly that the typical videos cluster low and a rare one sits
    # far in the tail — an absolute origin keeps that shape honest and keeps two
    # videos of the same channel comparable. `nil` for an empty input.
    def spread_histogram(values, buckets: SPREAD_BUCKETS)
      vals = values.compact.map(&:to_f)
      return nil if vals.empty?

      lo = 0.0
      hi = vals.max
      hi = 1.0 if hi <= lo # a window of all-zero views: one unit wide so edges are valid
      width = (hi - lo) / buckets
      edges = (0..buckets).map { |i| lo + (width * i) }
      counts = Array.new(buckets, 0)
      vals.each do |v|
        idx = ((v - lo) / width).to_i
        idx = idx.clamp(0, buckets - 1) # the max value lands in the last bar
        counts[idx] += 1
      end
      SpreadHistogram.new(counts:, edges:, min: vals.min, max: vals.max, n: vals.length)
    end

    # The Wilson score interval for a proportion `hits / n` at confidence `z`.
    #
    # Wilson, not Wald (p ± z·√(p(1−p)/n)): Wald's width collapses to zero at p=0 and
    # p=1 — frequent with rare attributes on a small n — falsely asserting absolute
    # certainty; Wilson keeps a sensible interval there. `n == 0` yields the whole
    # [0, 1] (no information), so an empty group never separates.
    def wilson_interval(hits, n, z)
      return [ 0.0, 1.0 ] if n <= 0

      phat = hits.to_f / n
      z2 = z * z
      denom = 1.0 + (z2 / n)
      center = (phat + (z2 / (2.0 * n))) / denom
      margin = (z / denom) * Math.sqrt((phat * (1.0 - phat) / n) + (z2 / (4.0 * n * n)))
      [ [ 0.0, center - margin ].max, [ 1.0, center + margin ].min ]
    end

    # ------------------------- outlier score -------------------------

    # Build the classification ruler from a same-format, already-windowed peer set.
    # `nil` when there are fewer than `min_sample` peers, or the median is
    # non-positive (no basis for a multiple) — both surface as "insufficient_sample"
    # downstream.
    #
    # Percentile basis: each band threshold is the nearest-rank percentile of the peer
    # views. Fixed-multiple basis (legacy): each threshold is median × the multiple.
    # Bands remain a pure per-channel metric — the project never enters.
    def band_ruler(peer_views, basis:, cutoffs:, min_sample:)
      vals = peer_views.map(&:to_i)
      return nil if vals.length < min_sample

      med = median(vals)
      return nil if med.nil? || med <= 0

      thresholds =
        case basis
        when "percentile"
          cutoffs.transform_values { |q| nearest_rank_percentile(vals, q) }
        when "fixed_multiple"
          cutoffs.transform_values { |mult| med * mult }
        else
          raise ArgumentError, "unknown band basis #{basis.inspect}"
        end
      BandRuler.new(median: med, sample_size: vals.length, basis:, cutoffs: cutoffs.dup, thresholds:)
    end

    # Classify `views` against a channel-format ruler. `median_multiple` is still
    # computed and carried (readable), but the `band` — the highest cutoff the views
    # reach — is the verdict. A young video is flagged provisional; an absent ruler
    # yields insufficient_sample.
    def outlier_score(views, ruler, provisional:)
      if ruler.nil?
        return OutlierScore.new(
          median_multiple: nil, band: nil, percentile: nil, band_basis: "",
          band_cutoffs: {}, provisional:, baseline: nil, sample_size: 0,
          status: "insufficient_sample"
        )
      end

      band = nil
      BAND_NAMES.each do |name| # ascending — the last one reached wins
        band = name if views >= ruler.thresholds[name]
      end
      percentile = (band && ruler.basis == "percentile") ? ruler.cutoffs[band] : nil
      OutlierScore.new(
        median_multiple: views / ruler.median,
        band:,
        percentile:,
        band_basis: ruler.basis,
        band_cutoffs: ruler.cutoffs.dup,
        provisional:,
        baseline: ruler.median,
        sample_size: ruler.sample_size,
        status: provisional ? "provisional" : "ok"
      )
    end

    # ------------------------- views-per-hour (deltas only) -------------------------

    def sorted_snaps(snaps)
      snaps.sort_by(&:captured_at)
    end
    private_class_method :sorted_snaps

    # Views-per-hour between each consecutive snapshot pair (pairs with a non-positive
    # elapsed time are skipped).
    def vph_series(snaps)
      ordered = sorted_snaps(snaps)
      out = []
      ordered.each_cons(2) do |a, b|
        hours = (b.captured_at - a.captured_at) / 3600.0
        next if hours <= 0

        out << VphPoint.new(from_at: a.captured_at, to_at: b.captured_at, hours:, vph: (b.views - a.views) / hours)
      end
      out
    end

    # VPH over the trailing `window_hours`, anchored at the latest snapshot: it is
    # compared against the newest snapshot at or before `latest − window_hours`
    # (falling back to the earliest snapshot if none is that old). `nil` when fewer
    # than two snapshots exist — VPH is never fabricated from totals.
    def current_vph(snaps, window_hours: 24.0)
      ordered = sorted_snaps(snaps)
      return nil if ordered.length < 2

      latest = ordered[-1]
      threshold = latest.captured_at - (window_hours * 3600)
      ref = ordered[0]
      ordered[0...-1].each { |s| ref = s if s.captured_at <= threshold }
      hours = (latest.captured_at - ref.captured_at) / 3600.0
      return nil if hours <= 0

      (latest.views - ref.views) / hours
    end

    # Average VPH over the snapshots observed within [start, finish]: the delta between
    # the first and last snapshot in the window over their elapsed hours. `nil` when
    # fewer than two snapshots fall inside the window.
    def window_vph(snaps, start, finish)
      inside = sorted_snaps(snaps).select { |s| s.captured_at >= start && s.captured_at <= finish }
      return nil if inside.length < 2

      hours = (inside[-1].captured_at - inside[0].captured_at) / 3600.0
      return nil if hours <= 0

      (inside[-1].views - inside[0].views) / hours
    end

    # ------------------------- resurgence -------------------------

    # Flag an OLD video (age >= `min_age_days`) whose current VPH is at least `k ×`
    # its recent trailing-average VPH. The recent baseline is the average VPH over the
    # `baseline_days` ending one window before now, so it excludes the current spike.
    # `min_vph` guards a ~0 baseline from producing a spurious hit.
    def resurgence(snaps, published_at:, now:, min_age_days:, k:, baseline_days:, min_vph:, window_hours: 24.0)
      current = current_vph(snaps, window_hours:)
      base_end = now - (window_hours * 3600)
      base_start = base_end - (baseline_days * 86_400)
      recent_avg = window_vph(snaps, base_start, base_end)

      return Resurgence.new(is_resurgent: false, ratio: nil, current_vph: current, recent_avg_vph: recent_avg) if published_at.nil?

      age_days = (now - published_at) / 86_400.0
      if age_days < min_age_days || current.nil? || current < min_vph
        ratio = [ nil, 0 ].include?(recent_avg) ? nil : current / recent_avg
        return Resurgence.new(is_resurgent: false, ratio:, current_vph: current, recent_avg_vph: recent_avg)
      end
      if recent_avg.nil? || recent_avg <= 0
        # Dormant then spiking: a real resurgence, but the ratio is undefined.
        return Resurgence.new(is_resurgent: true, ratio: nil, current_vph: current, recent_avg_vph: recent_avg)
      end
      ratio = current / recent_avg
      Resurgence.new(is_resurgent: ratio >= k, ratio:, current_vph: current, recent_avg_vph: recent_avg)
    end

    # ------------------------- packaging impact -------------------------

    # Mean VPH in the `window_days` before vs after a packaging change. The "after"
    # side is computed only once the window has fully elapsed.
    def packaging_impact(snaps, detected_at:, now:, window_days: 7)
      delta = window_days * 86_400
      before = window_vph(snaps, detected_at - delta, detected_at)
      after = nil
      after = window_vph(snaps, detected_at, detected_at + delta) if now >= detected_at + delta
      Impact.new(vph_before: before, vph_after: after)
    end

    # ------------------------- engagement & cadence -------------------------

    def engagement_rates(views, likes, comments)
      return Engagement.new(like_rate: nil, comment_rate: nil) if views <= 0

      Engagement.new(like_rate: likes.to_f / views, comment_rate: comments.to_f / views)
    end

    # Descriptive upload cadence: uploads/week over the observed history and the
    # distribution of publish weekday/hour, plus median duration per format. Weekday
    # follows Python's convention (Monday = 0 … Sunday = 6) so payloads match.
    def cadence(videos, now:)
      pubs = videos.filter_map(&:published_at).sort
      by_weekday = Hash.new(0)
      by_hour = Hash.new(0)
      pubs.each do |ts|
        by_weekday[(ts.wday + 6) % 7] += 1
        by_hour[ts.hour] += 1
      end

      uploads_per_week =
        if pubs.any?
          span_days = [ (now - pubs[0]) / 86_400.0, 7.0 ].max
          pubs.length / (span_days / 7.0)
        else
          0.0
        end

      duration_by_format = {}
      [ [ "short", true ], [ "long", false ] ].each do |fmt, is_short|
        durations = videos.select { |v| v.is_short == is_short }.map(&:duration_s)
        med = median(durations)
        duration_by_format[fmt] = { "median_s" => med, "count" => durations.length } unless med.nil?
      end

      Cadence.new(uploads_per_week:, by_weekday: by_weekday.to_h, by_hour: by_hour.to_h, duration_by_format:)
    end
  end
end
