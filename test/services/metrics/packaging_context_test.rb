require "test_helper"

# Tests the deterministic packaging input. The band basis is `fixed_multiple` so a
# clean control/outlier split falls out of the view counts (median 100 → relevant at
# 3x = 300). Ported from the packaging cases of the PoC `tests/`.
class Metrics::PackagingContextTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 7, 14, 12, 0, 0)
  CONFIG = Metrics::Config.new(band_basis: "fixed_multiple")

  setup do
    @project = Project.create!(name: "Niche")
    @channel = CompetitorChannel.create!(youtube_channel_id: "UCc")
    @project.project_channels.create!(competitor_channel: @channel)
  end

  def add_video(id, views:, attrs:)
    v = @channel.competitor_videos.create!(youtube_video_id: id, title: "T-#{id}", published_at: NOW - 40.days, duration_s: 600, is_short: false)
    v.video_snapshots.create!(captured_at: NOW - 1.day, views:, likes: 0, comments: 0)
    v.video_attributes.create!(source: "title_llm", state: "done", content_hash: "h#{id}", attrs:)
    v
  end

  def context(fmt: "long") = Metrics::PackagingContext.new(@project, config: CONFIG, now: NOW, fmt:).call

  test "surfaces differential, conventions, carries_value and examples" do
    8.times { |i| add_video("ctl#{i}", views: 100, attrs: { "title_has_person_name" => false, "title_tone_hype" => true, "person_names" => [] }) }
    5.times { |i| add_video("out#{i}", views: 500, attrs: { "title_has_person_name" => true, "title_tone_hype" => true, "person_names" => [ "Fulano de Tal" ] }) }

    ctx = context

    assert_equal 1, ctx[:niche][:channels]
    assert_equal 5, ctx[:niche][:outliers]
    assert_equal false, ctx[:flat]

    diff_attrs = ctx[:differential].map { |d| d[:attribute] }
    assert_includes diff_attrs, "title_has_person_name" # separates outliers from control
    refute_includes diff_attrs, "title_tone_hype"       # near-universal → overlaps → not a differential

    conv_attrs = ctx[:conventions].map { |c| c[:attribute] }
    assert_includes conv_attrs, "title_tone_hype"        # table-stakes across the niche
    refute_includes conv_attrs, "title_has_person_name"  # already reported as a differential

    carries = ctx[:carries_value]["person_names"]
    assert_equal 1, carries.size
    assert_equal "Fulano de Tal", carries[0][:value]
    assert_equal 5, carries[0][:videos_outlier]
    assert_equal 0, carries[0][:videos_control]

    assert_equal 5, ctx[:examples].size
    assert ctx[:examples].all? { |e| e[:band] == "relevant" }
    assert ctx[:examples].all? { |e| e[:title_attrs]["title_has_person_name"] == true }
  end

  test "a niche where nothing separates and nothing carries is flat" do
    13.times { |i| add_video("v#{i}", views: 100, attrs: { "title_tone_hype" => true, "person_names" => [] }) }

    ctx = context

    assert_equal 0, ctx[:niche][:outliers]
    assert_empty ctx[:differential]
    assert_empty ctx[:carries_value]["person_names"]
    assert_equal true, ctx[:flat]
  end
end
