require "test_helper"

# The Niche screen renders the NicheDashboard payload across its three tabs
# (patterns / outliers / channels), server-rendered via ?tab=.
class NicheScreenTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Chess")
    @channel = CompetitorChannel.create!(youtube_channel_id: "UC_solo", title: "Solo", handle: "@solo")
    @project.project_channels.create!(competitor_channel: @channel)
    @channel.channel_snapshots.create!(captured_at: Time.current, subscribers: 12_345)
    @seq = 0
    20.times { video(title: "plain #{@seq}", views: 1000) }         # control, no '?'
    10.times { video(title: "Question #{@seq}?", views: 100_000) }  # banded outliers
    @channel.competitor_videos.each do |v|
      v.video_attributes.create!(source: Metrics::Attributes::SOURCE, state: "done",
        attrs: Metrics::Attributes.syntactic_attributes(v.title))
    end
  end

  def video(title:, views:)
    @seq += 1
    v = @channel.competitor_videos.create!(youtube_video_id: "v#{@seq}", title:, published_at: 60.days.ago)
    v.video_snapshots.create!(captured_at: 1.hour.ago, views:)
    v
  end

  test "defaults to the patterns tab" do
    get project_niche_path(@project)
    assert_response :success
    assert_select "a.tab.on", text: "Patterns"
    assert_select "td.font-mono", text: "has_question" # the separating attribute
  end

  test "outliers tab ranks the banded videos with their band tag" do
    get project_niche_path(@project, tab: "outliers", fmt: "long")
    assert_response :success
    assert_select "a.tab.on", text: "Outliers"
    assert_select "tbody tr", count: 10           # the 10 banded outliers
    assert_select "span.tag", text: "p99"         # percentile band evidence
    assert_select "td", text: /Question/          # a real outlier title
  end

  test "channels tab lists the tracked competitor and its subscribers" do
    get project_niche_path(@project, tab: "channels")
    assert_response :success
    assert_select "a.tab.on", text: "Channels"
    assert_select "td", text: "Solo"
    assert_select "td.font-mono", text: "12.3k"
  end

  test "format chips switch the population" do
    get project_niche_path(@project, tab: "outliers", fmt: "short")
    assert_response :success
    assert_select "p.m", text: "No outlier in this format yet." # no Shorts exist
  end
end
