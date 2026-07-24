require "test_helper"

# Unit tests for the pure metrics core (guideline 10 methodology). Ported verbatim
# from the PoC `tests/test_metrics_core.py` to lock exact numeric parity. No DB, no
# network — the methodology is exercised directly on synthetic values.
class Metrics::CoreTest < ActiveSupport::TestCase
  C = Metrics::Core

  NOW = Time.utc(2026, 7, 14, 12, 0, 0)
  FIXED = C.parse_cutoffs("3,6,10")   # legacy fixed-multiple cutoffs
  PCT = C.parse_cutoffs("90,97,99")   # percentile cutoffs

  def fixed_ruler(peers)
    C.band_ruler(peers, basis: "fixed_multiple", cutoffs: FIXED, min_sample: 10)
  end

  def snap(at, views) = C::Snap.new(captured_at: at, views:)

  # --- baseline: median, robust to a viral ---

  test "baseline is median robust to one viral" do
    peers = [ 900, 950, 1000, 1000, 1050, 1100, 1000, 980, 1020, 1000, 1_000_000 ]
    ruler = fixed_ruler(peers)
    refute_nil ruler
    # The mean would be ~92k (wrecked by the viral); the median stays ~1000.
    assert_operator ruler.median, :>=, 950
    assert_operator ruler.median, :<=, 1050
    viral = C.outlier_score(1_000_000, ruler, provisional: false)
    assert_equal "exceptional", viral.band
    assert_operator viral.median_multiple, :>, 900
  end

  test "insufficient sample below min_sample" do
    ruler = fixed_ruler([ 1000 ] * 9) # only 9 peers
    assert_nil ruler
    score = C.outlier_score(5000, ruler, provisional: false)
    assert_equal "insufficient_sample", score.status
    assert_nil score.median_multiple
    assert_nil score.band
  end

  # --- Shorts vs long-form separation ---

  test "shorts and long-form use separate baselines" do
    short_ruler = fixed_ruler([ 500 ] * 10)    # low Short baseline
    long_ruler = fixed_ruler([ 10_000 ] * 10)  # high long baseline
    views = 5000
    short_score = C.outlier_score(views, short_ruler, provisional: false)
    long_score = C.outlier_score(views, long_ruler, provisional: false)
    # Same view count, different verdict — because the baselines differ by format.
    assert_equal 10.0, short_score.median_multiple
    assert_equal "exceptional", short_score.band
    assert_equal 0.5, long_score.median_multiple
    assert_nil long_score.band
  end

  # --- provisional vs definitive ---

  test "provisional flag for young video" do
    ruler = fixed_ruler([ 1000 ] * 10)
    young = C.outlier_score(4000, ruler, provisional: true)
    mature = C.outlier_score(4000, ruler, provisional: false)
    assert young.provisional
    assert_equal "provisional", young.status
    refute mature.provisional
    assert_equal "ok", mature.status
    assert_equal 4.0, young.median_multiple
    assert_equal 4.0, mature.median_multiple
    assert_equal "relevant", young.band
  end

  # --- percentile bands (the default basis) ---

  test "percentile bands classify by channel tail" do
    # 1..100: median 50.5; nearest-rank cutoffs land on the 90th/97th/99th values.
    peers = (1..100).to_a
    ruler = C.band_ruler(peers, basis: "percentile", cutoffs: PCT, min_sample: 10)
    assert_equal({ "relevant" => 90.0, "strong" => 97.0, "exceptional" => 99.0 }, ruler.thresholds)
    below = C.outlier_score(50, ruler, provisional: false)
    relevant = C.outlier_score(95, ruler, provisional: false)
    exceptional = C.outlier_score(100, ruler, provisional: false)
    assert_nil below.band
    # Percentile basis carries the cutoff percentile as evidence.
    assert_equal "relevant", relevant.band
    assert_equal 90.0, relevant.percentile
    assert_equal "exceptional", exceptional.band
    assert_equal 99.0, exceptional.percentile
    assert_equal "percentile", relevant.band_basis
    # Fixed-multiple basis has no percentile evidence.
    assert_nil C.outlier_score(95, fixed_ruler(peers), provisional: false).percentile
  end

  test "nearest rank collapses top cutoffs at min sample" do
    # With n=10, ceil(0.97·10)=ceil(0.99·10)=10 → p97 and p99 are both the maximum.
    vals = (1..10).to_a
    assert_equal 9.0, C.nearest_rank_percentile(vals, 90)
    assert_equal 10.0, C.nearest_rank_percentile(vals, 97)
    assert_equal 10.0, C.nearest_rank_percentile(vals, 99)
    assert_equal 1.0, C.nearest_rank_percentile(vals, 0)
    assert_nil C.nearest_rank_percentile([], 90)
  end

  # --- channel spread histogram ---

  test "spread histogram shape and counts" do
    hist = C.spread_histogram([ 0, 25, 50, 75, 100 ], buckets: 4)
    assert_equal 4, hist.counts.length
    assert_equal 5, hist.edges.length
    # Half-open [lo, hi) bars over [0, 100]: 0→bar0, 25→bar1, 50→bar2, 75→bar3, and
    # the max (100) is clamped into the last bar rather than a phantom fifth.
    assert_equal [ 0.0, 25.0, 50.0, 75.0, 100.0 ], hist.edges
    assert_equal [ 1, 1, 1, 2 ], hist.counts
    assert_equal 0.0, hist.min
    assert_equal 100.0, hist.max
    assert_equal 5, hist.n
  end

  test "spread histogram puts a lone viral in the tail" do
    peers = ([ 1000 ] * 20) + [ 100_000 ]
    hist = C.spread_histogram(peers)
    assert_equal C::SPREAD_BUCKETS, hist.counts.length
    assert_equal 20, hist.counts.first # the cluster
    assert_equal 1, hist.counts.last   # the viral, alone in the last bar
    assert_equal 21, hist.counts.sum
  end

  test "spread histogram empty is nil" do
    assert_nil C.spread_histogram([])
    assert_nil C.spread_histogram([ nil, nil ])
  end

  test "spread histogram all zero views is valid" do
    hist = C.spread_histogram([ 0, 0, 0 ], buckets: 4)
    assert_equal [ 3, 0, 0, 0 ], hist.counts
    assert_equal 0.0, hist.max
    assert_equal 1.0, hist.edges.last
  end

  test "wilson interval keeps width at extremes" do
    # Wald would give width 0 at p=1 (falsely certain); Wilson stays an interval.
    lo, hi = C.wilson_interval(3, 3, 1.96)
    assert_operator hi - lo, :>, 0
    assert_operator lo, :<, 1.0
    assert_operator hi, :<=, 1.0
    lo0, hi0 = C.wilson_interval(0, 3, 1.96)
    assert_operator hi0, :>, 0
    assert_equal 0.0, lo0
    # An empty group carries no information — the whole [0, 1].
    assert_equal [ 0.0, 1.0 ], C.wilson_interval(0, 0, 1.96)
  end

  # --- VPH strictly from deltas ---

  test "current vph from two snapshots" do
    snaps = [ snap(NOW - (24 * 3600), 100), snap(NOW, 340) ]
    assert_equal 10.0, C.current_vph(snaps, window_hours: 24) # 240 views / 24 h
  end

  test "vph nil with single snapshot" do
    assert_nil C.current_vph([ snap(NOW, 500) ], window_hours: 24)
  end

  test "vph series pairwise deltas" do
    snaps = [ snap(NOW - (2 * 3600), 0), snap(NOW - (1 * 3600), 10), snap(NOW, 40) ]
    assert_equal [ 10.0, 30.0 ], C.vph_series(snaps).map(&:vph)
  end

  # --- resurgence ---

  test "resurgence old video current vph exceeds recent average" do
    # 8-day series: low baseline VPH (~10/h) then a spike in the last 24 h (~100/h).
    snaps = []
    views = 0
    8.downto(1) do |day|
      snaps << snap(NOW - (day * 86_400), views)
      views += 240 # ~10 views/hour across each prior day
    end
    snaps << snap(NOW, views + 2400) # last 24 h: 2400 views = 100/h
    res = C.resurgence(
      snaps, published_at: NOW - (120 * 86_400), now: NOW,
      min_age_days: 30, k: 3.0, baseline_days: 7, min_vph: 1.0
    )
    assert res.is_resurgent
    refute_nil res.current_vph
    refute_nil res.recent_avg_vph
    refute_nil res.ratio
    assert_operator res.ratio, :>=, 3.0
  end

  test "no resurgence for young video" do
    snaps = [ snap(NOW - (24 * 3600), 0), snap(NOW, 10_000) ]
    res = C.resurgence(
      snaps, published_at: NOW - (3 * 86_400), now: NOW,
      min_age_days: 30, k: 3.0, baseline_days: 7, min_vph: 1.0
    )
    refute res.is_resurgent
  end

  # --- packaging impact ---

  test "packaging impact before and after when elapsed" do
    detected = NOW - (8 * 86_400) # window fully elapsed
    snaps = [
      snap(detected - (7 * 86_400), 0),
      snap(detected, 700),                   # before: 700 views / 7 d ≈ 4.17/h
      snap(detected + (7 * 86_400), 4900)    # after: 4200 / 7 d = 25/h
    ]
    impact = C.packaging_impact(snaps, detected_at: detected, now: NOW, window_days: 7)
    refute_nil impact.vph_before
    refute_nil impact.vph_after
    assert_operator impact.vph_after, :>, impact.vph_before
  end

  test "packaging impact after nil until window elapsed" do
    detected = NOW - (2 * 86_400) # only 2 days elapsed of a 7-day window
    snaps = [ snap(detected - (7 * 86_400), 0), snap(detected, 700), snap(NOW, 900) ]
    impact = C.packaging_impact(snaps, detected_at: detected, now: NOW, window_days: 7)
    assert_nil impact.vph_after
  end

  # --- engagement & cadence ---

  test "engagement rates and zero views guard" do
    e = C.engagement_rates(1000, 80, 6)
    assert_equal 0.08, e.like_rate
    assert_equal 0.006, e.comment_rate
    assert_nil C.engagement_rates(0, 0, 0).like_rate
  end

  test "cadence uploads per week and distributions" do
    vids = [
      C::VideoMeta.new(published_at: NOW - (7 * 86_400), is_short: false, duration_s: 600),
      C::VideoMeta.new(published_at: NOW - (14 * 86_400), is_short: false, duration_s: 720),
      C::VideoMeta.new(published_at: NOW - (21 * 86_400), is_short: true, duration_s: 45)
    ]
    c = C.cadence(vids, now: NOW)
    assert_operator c.uploads_per_week, :>, 0
    assert_equal 3, c.by_weekday.values.sum
    assert_equal 3, c.by_hour.values.sum
    assert_equal 45, c.duration_by_format["short"]["median_s"]
    assert_equal 660, c.duration_by_format["long"]["median_s"]
  end

  test "parse cutoffs" do
    assert_equal({ "relevant" => 90.0, "strong" => 97.0, "exceptional" => 99.0 }, C.parse_cutoffs("90,97,99"))
    # Sorted onto the ascending band names regardless of input order.
    assert_equal({ "relevant" => 3.0, "strong" => 6.0, "exceptional" => 10.0 }, C.parse_cutoffs("10, 3 ,6"))
    [ "3,6", "3,6,10,12", "" ].each do |bad|
      assert_raises(ArgumentError, "expected ArgumentError for #{bad.inspect}") { C.parse_cutoffs(bad) }
    end
  end
end
