require "test_helper"

# Tests for the conditional distributions + the Wilson non-overlap guard. Ported
# verbatim from the PoC `tests/test_metrics_patterns.py`. Pins the four scenarios:
# positive, inconclusive, anti-pattern, and the p=1/n=3 trap that a Wald interval
# would wave through as absolute certainty.
class Metrics::PatternsTest < ActiveSupport::TestCase
  Z = 1.96 # 95%

  # `n` attribute rows, the first `hits` of them exhibiting `attr`.
  def rows(n, hits, attr = "has_question")
    Array.new(n) { |i| { attr => i < hits } }
  end

  def get(reported, attr)
    reported.find { |p| p.attribute == attr }
  end

  def patterns(outliers, control)
    Metrics::Patterns.conditional_patterns(outliers, control, z: Z)
  end

  test "strong lift separates as positive" do
    # 80% of outliers vs 30% of control — the intervals clear each other.
    p = get(patterns(rows(50, 40), rows(50, 15)), "has_question")
    refute_nil p
    assert_equal "positive", p.verdict
    assert_equal 0.8, p.freq_outlier
    assert_equal 0.3, p.freq_control
    assert_equal (0.8 / 0.3).round(3), p.lift.round(3)
    assert_equal 50, p.n_outlier
    assert_equal 50, p.n_control
    assert_operator p.ci_outlier[0], :>, p.ci_control[1] # non-overlap, outlier above
  end

  test "near even split is inconclusive" do
    # 52% vs 48% — the intervals overlap heavily, nothing is reported.
    assert_nil get(patterns(rows(50, 26), rows(50, 24)), "has_question")
  end

  test "rarer in outliers reports as negative" do
    # 10% of outliers vs 45% of control — an actionable anti-pattern to avoid.
    p = get(patterns(rows(50, 5), rows(40, 18)), "has_question")
    refute_nil p
    assert_equal "negative", p.verdict
    assert_operator p.ci_outlier[1], :<, p.ci_control[0] # non-overlap, outlier below
  end

  test "p1 with n3 does not pass" do
    # 3/3 outliers exhibit it (Wald would give the zero-width interval [1, 1] and
    # falsely separate). Wilson's interval for n=3 is wide and overlaps the 80%
    # control, so the attribute is correctly withheld.
    assert_nil get(patterns(rows(3, 3), rows(50, 40)), "has_question")
  end

  test "contaminated denominator hides the pattern" do
    # 75% of outliers vs 40% of a proper (outlier-free) control — a real signal.
    outliers = rows(40, 30)
    control = rows(60, 24)
    good = get(patterns(outliers, control), "has_question")
    refute_nil good
    assert_equal "positive", good.verdict

    # The legacy denominator put the outliers back INTO the comparison group,
    # pulling its rate up to 54% — the intervals now overlap and the signal is crushed.
    contaminated = outliers + control
    assert_nil get(patterns(outliers, contaminated), "has_question")
    assert_operator good.lift, :>, (0.75 / 0.54) # the true lift is larger than the compressed one
  end

  test "empty group returns nothing" do
    assert_equal [], patterns([], [ { "has_question" => true } ])
    assert_equal [], patterns([ { "has_question" => true } ], [])
  end
end
