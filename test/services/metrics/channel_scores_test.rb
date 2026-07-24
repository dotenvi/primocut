require "test_helper"

# DB-backed tests for the per-channel outlier scoring. Mirrors the PoC
# service.py::_channel_scores behaviour: a robust per-format band ruler over the
# latest snapshot views, provisional flagging for young videos, and
# insufficient_sample when a format lacks enough peers. The clock is injected so the
# "young vs mature" boundary is deterministic.
class Metrics::ChannelScoresTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 7, 14, 12, 0, 0)

  setup do
    @channel = CompetitorChannel.create!(youtube_channel_id: "UC_test", title: "Test")
    @seq = 0
  end

  # Create a video with a single snapshot of `views`, published `age_days` ago.
  def add_video(views:, age_days: 60, is_short: false)
    @seq += 1
    video = @channel.competitor_videos.create!(
      youtube_video_id: "vid#{@seq}", title: "V#{@seq}",
      is_short:, published_at: NOW - (age_days * 86_400)
    )
    video.video_snapshots.create!(captured_at: NOW - (age_days * 86_400) + 3600, views:)
    video
  end

  def scored_for(video)
    Metrics::ChannelScores.new(@channel, now: NOW).call.scored[video.id]
  end

  test "a viral scores exceptional against a robust median baseline" do
    10.times { add_video(views: 1000) } # a tight cluster of typical long-form videos
    viral = add_video(views: 1_000_000)

    result = Metrics::ChannelScores.new(@channel, now: NOW).call
    assert_equal "exceptional", result.scored[viral.id].score.band
    # The median stays ~1000 (robust to the viral), so the multiple is enormous.
    assert_operator result.scored[viral.id].score.median_multiple, :>, 900
  end

  test "a typical video stays below the relevant band" do
    10.times { add_video(views: 1000) }
    typical = add_video(views: 500) # clearly below the channel's p90 tail cutoff
    add_video(views: 1_000_000)     # a viral in the window lifts the tail cutoffs

    assert_nil scored_for(typical).score.band
  end

  test "insufficient sample when a format lacks enough peers" do
    5.times { add_video(views: 1000) } # only 5 long-form peers, below min_sample 10
    v = add_video(views: 5000)

    assert_equal "insufficient_sample", scored_for(v).score.status
    assert_nil scored_for(v).score.band
  end

  test "a young video is flagged provisional" do
    10.times { add_video(views: 1000) }
    young = add_video(views: 4000, age_days: 2) # inside the 7-day provisional window

    s = scored_for(young)
    assert s.score.provisional
    assert_equal "provisional", s.score.status
  end

  test "shorts and long-form are scored against separate baselines" do
    10.times { add_video(views: 500, is_short: true) }  # low Short baseline
    10.times { add_video(views: 10_000, is_short: false) } # high long baseline
    short_hit = add_video(views: 5000, is_short: true)
    long_same = add_video(views: 5000, is_short: false)

    result = Metrics::ChannelScores.new(@channel, now: NOW).call
    # Same 5000 views, opposite verdicts — because the baselines differ by format.
    assert_equal "exceptional", result.scored[short_hit.id].score.band
    assert_nil result.scored[long_same.id].score.band
  end

  test "a video with no snapshot is not scored" do
    10.times { add_video(views: 1000) }
    unscored = @channel.competitor_videos.create!(
      youtube_video_id: "no_snap", title: "No snap", published_at: NOW - (60 * 86_400)
    )

    assert_nil Metrics::ChannelScores.new(@channel, now: NOW).call.scored[unscored.id]
  end
end
