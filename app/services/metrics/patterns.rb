module Metrics
  # Per-project conditional distributions of title/thumbnail attributes. Ported
  # verbatim from the PoC `metrics/patterns.py` (pure — no DB). The rationale is
  # preserved (AGENTS.md §2.4):
  #
  # For each boolean attribute we compare how often it appears among a project's
  # outliers versus a matched CONTROL group, reporting the lift and a verdict. The
  # control is the non-outlier, mature, sufficient-baseline videos — never the whole
  # population: a population that contains the outliers themselves puts the numerator
  # inside the denominator and crushes every lift toward 1.0.
  #
  # An attribute is reported only when the 95% Wilson score intervals of its two
  # frequencies do not overlap, in either direction (positive pattern or anti-pattern).
  # Wilson, not Wald, because Wald's width collapses to zero at p=0/p=1. There is no
  # minimum-n floor: a small group yields a wide interval that never separates.
  #
  # Callers pass ONE source's attributes at a time (syntactic, title_llm,
  # thumbnail_llm) with each group restricted to the videos that have a row for it.
  module Patterns
    Pattern = Data.define(
      :attribute, :freq_outlier, :ci_outlier, :freq_control, :ci_control,
      :lift, :n_outlier, :n_control, :verdict, :source
    )

    module_function

    # Frequency of each boolean attribute among `outliers` vs `control`.
    #
    # Both sequences must come from the SAME attribute source, each restricted to the
    # videos that have a row for it. `source` tags the results so a dashboard can
    # merge several sources without losing where each came from.
    #
    # An attribute is returned only when its two Wilson intervals (`z`) do not
    # overlap: lower(outlier) > upper(control) is a positive pattern, upper(outlier) <
    # lower(control) an anti-pattern; anything else is inconclusive and dropped.
    # Results are sorted by descending effect size (lift), not by significance.
    def conditional_patterns(outliers, control, z:, source: "")
      return [] if outliers.empty? || control.empty?

      n_out = outliers.length
      n_ctl = control.length
      results = []

      (boolean_attributes(outliers) | boolean_attributes(control)).sort.each do |attr|
        out_hits = outliers.count { |a| a[attr] == true }
        ctl_hits = control.count { |a| a[attr] == true }
        freq_out = out_hits.to_f / n_out
        freq_ctl = ctl_hits.to_f / n_ctl
        lo_out, hi_out = Core.wilson_interval(out_hits, n_out, z)
        lo_ctl, hi_ctl = Core.wilson_interval(ctl_hits, n_ctl, z)

        verdict =
          if lo_out > hi_ctl
            "positive"
          elsif hi_out < lo_ctl
            "negative"
          else
            next # intervals overlap — inconclusive, not reported
          end

        lift = freq_ctl > 0 ? freq_out / freq_ctl : nil
        results << Pattern.new(
          attribute: attr, freq_outlier: freq_out, ci_outlier: [ lo_out, hi_out ],
          freq_control: freq_ctl, ci_control: [ lo_ctl, hi_ctl ], lift:,
          n_outlier: n_out, n_control: n_ctl, verdict:, source:
        )
      end

      # Descending by lift; a nil lift (no control hits) sorts to the top, matching
      # Python's None→inf under reverse. Stable on ties via the original index.
      results.each_with_index.sort_by { |p, i| [ -(p.lift || Float::INFINITY), i ] }.map(&:first)
    end

    def boolean_attributes(rows)
      keys = []
      rows.each do |attrs|
        attrs.each { |key, value| keys << key if [ true, false ].include?(value) }
      end
      keys.uniq
    end
    private_class_method :boolean_attributes
  end
end
