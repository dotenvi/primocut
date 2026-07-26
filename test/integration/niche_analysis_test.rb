require "test_helper"

# The opt-in AI analysis on the Patterns tab: the button prices the click before
# it happens, and the click dispatches only what is not already cached.
class NicheAnalysisTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @project = Project.create!(name: "Chess")
    @channel = CompetitorChannel.create!(youtube_channel_id: "UC_solo", title: "Solo")
    @project.project_channels.create!(competitor_channel: @channel)
    @seq = 0
  end

  def populate(controls: 20, outliers: 2)
    controls.times { |i| video(views: 1_000 + (i * 120)) }
    outliers.times { video(views: 500_000) }
  end

  def video(views:)
    @seq += 1
    v = @channel.competitor_videos.create!(youtube_video_id: "v#{@seq}", title: "Video #{@seq}",
      published_at: 90.days.ago)
    v.video_snapshots.create!(captured_at: 1.hour.ago, views: views)
    v
  end

  test "the tab renders the buttons without waiting for their price" do
    populate

    get project_niche_path(@project, tab: "patterns")
    assert_response :success
    # Lazy frames: the tab must not pay for the scoring the price needs.
    assert_select "turbo-frame#analysis_title[loading=?][src=?]", "lazy",
      project_niche_analysis_path(@project, kind: "title")
    assert_select "turbo-frame#analysis_thumbnail[loading=?]", "lazy"
  end

  test "the buttons are absent on the other tabs" do
    populate

    get project_niche_path(@project, tab: "outliers")
    assert_select "turbo-frame#analysis_title", count: 0
  end

  test "the price names how many videos the click would pay for" do
    populate

    get project_niche_analysis_path(@project, kind: "title")
    assert_response :success
    assert_select "button", text: "Analyze titles · 22 new"
  end

  test "a fully cached kind says so instead of quoting a price" do
    populate
    @channel.competitor_videos.each do |v|
      v.video_attributes.create!(source: "title_llm", state: "done", attrs: {},
        content_hash: Metrics::Attributes.title_content_hash(v.title))
    end

    get project_niche_analysis_path(@project, kind: "title")
    assert_select "button", text: "Analyze titles · all cached"
  end

  test "an empty niche offers a disabled button" do
    get project_niche_analysis_path(@project, kind: "title")
    assert_response :success
    assert_select "button[disabled]", text: "Analyze titles"
  end

  test "an unknown kind is not found" do
    get project_niche_analysis_path(@project, kind: "bogus")
    assert_response :not_found
  end

  test "clicking dispatches only the videos that are not cached" do
    populate
    cached = @channel.competitor_videos.first
    cached.video_attributes.create!(source: "title_llm", state: "done", attrs: {},
      content_hash: Metrics::Attributes.title_content_hash(cached.title))

    assert_enqueued_with(job: Competitors::VideoAnalysisJob) do
      post project_niche_analysis_path(@project), params: { kind: "title" }
    end

    ids = enqueued_jobs.find { |j| j["job_class"] == "Competitors::VideoAnalysisJob" }["arguments"].first
    assert_equal 21, ids.size
    assert_not_includes ids, cached.youtube_video_id, "a cache hit must never be recharged"

    assert_redirected_to project_niche_path(@project)
    follow_redirect!
    assert_select ".text-ok", text: /Analyzing 21 videos \(1 already cached\)/
  end

  test "clicking with everything cached queues nothing" do
    populate
    @channel.competitor_videos.each do |v|
      v.video_attributes.create!(source: "title_llm", state: "done", attrs: {},
        content_hash: Metrics::Attributes.title_content_hash(v.title))
    end

    assert_no_enqueued_jobs only: Competitors::VideoAnalysisJob do
      post project_niche_analysis_path(@project), params: { kind: "title" }
    end

    follow_redirect!
    assert_select ".text-ok", text: /already analyzed — nothing to pay for/
  end

  test "clicking an empty niche spends nothing and says why" do
    assert_no_enqueued_jobs only: Competitors::VideoAnalysisJob do
      post project_niche_analysis_path(@project), params: { kind: "title" }
    end

    follow_redirect!
    assert_select ".text-ok", text: /No settled video to analyze yet/
  end
end
