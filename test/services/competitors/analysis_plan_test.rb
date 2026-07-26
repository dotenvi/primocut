require "test_helper"

# Pricing the opt-in AI analysis before the click. The price must come from the
# very same cache gate the job uses, or the button lies about what it will spend.
class Competitors::AnalysisPlanTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Chess")
    @channel = CompetitorChannel.create!(youtube_channel_id: "UC_solo", title: "Solo")
    @project.project_channels.create!(competitor_channel: @channel)
    @seq = 0
  end

  # A settled score needs a real peer population, so the control group is built
  # wholesale and the outliers are the few with runaway views.
  def video(views:, published_at: 90.days.ago, title: nil)
    @seq += 1
    v = @channel.competitor_videos.create!(youtube_video_id: "v#{@seq}",
      title: title || "Video #{@seq}", published_at: published_at)
    v.video_snapshots.create!(captured_at: 1.hour.ago, views: views)
    v
  end

  # Control views are spread, not identical: a flat population makes the
  # percentile cutoffs land on the whole group and everything reads as banded.
  def populate(controls: 20, outliers: 2)
    controls.times { |i| video(views: 1_000 + (i * 120)) }
    outliers.times { video(views: 500_000) }
  end

  def cache!(video, source: "title_llm", hash: nil)
    video.video_attributes.create!(source: source, state: "done",
      content_hash: hash || Metrics::Attributes.title_content_hash(video.title), attrs: {})
  end

  test "prices every settled video for a pattern kind" do
    populate

    plan = Competitors::AnalysisPlan.new(@project, kind: "title").call

    assert_equal 22, plan.total
    assert_equal 22, plan.pending_count
    assert_equal 0, plan.cached
    assert plan.any?
  end

  test "a video already analyzed is cached, not charged again" do
    populate
    cache!(@channel.competitor_videos.first)

    plan = Competitors::AnalysisPlan.new(@project, kind: "title").call

    assert_equal 1, plan.cached
    assert_equal 21, plan.pending_count
    assert_equal 22, plan.total
  end

  test "a changed title falls out of the cache" do
    populate
    stale = @channel.competitor_videos.first
    cache!(stale, hash: "a-hash-from-an-older-title")

    plan = Competitors::AnalysisPlan.new(@project, kind: "title").call

    assert_equal 0, plan.cached
    assert_includes plan.pending, stale.youtube_video_id
  end

  test "comments target only the settled outliers, not the whole population" do
    populate(controls: 20, outliers: 2)

    titles = Competitors::AnalysisPlan.new(@project, kind: "title").call
    comments = Competitors::AnalysisPlan.new(@project, kind: "comments").call

    assert_equal 22, titles.total, "both sides of the comparison need the attribute"
    assert_operator comments.total, :<, titles.total, "comments summarise one group, not both"
    assert_operator comments.total, :>=, 2, "the runaway videos are in it"
  end

  test "a provisional video is not priced — its verdict has not settled" do
    populate
    video(views: 900_000, published_at: 1.day.ago) # too young to have a real score

    plan = Competitors::AnalysisPlan.new(@project, kind: "title").call

    assert_equal 22, plan.total, "the young video stays out until its score settles"
  end

  test "a video that cannot be gated is counted as payable, not hidden" do
    populate
    # No thumbnail hash has ever been recorded, so the gate cannot answer — the job
    # will attempt it and surface the failure, and the price must say so.
    plan = Competitors::AnalysisPlan.new(@project, kind: "thumbnail").call

    assert_equal 22, plan.pending_count
    assert_equal 0, plan.cached
  end

  test "an empty niche prices nothing" do
    plan = Competitors::AnalysisPlan.new(@project, kind: "title").call

    assert_equal 0, plan.total
    assert_not plan.any?
  end

  test "an unknown kind is refused rather than priced" do
    populate

    assert_raises(Competitors::VideoAnalysis::UnknownKind) do
      Competitors::AnalysisPlan.new(@project, kind: "bogus").call
    end
  end
end
