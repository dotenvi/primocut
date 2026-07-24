require "test_helper"

# Tests for the pure syntactic title attributes + content hash. Ported from the PoC
# `tests/test_metrics_attributes.py` (the persistence/idempotency test covers a write
# and belongs to the collection phase, not this read-only slice).
class Metrics::AttributesTest < ActiveSupport::TestCase
  A = Metrics::Attributes

  test "syntactic features" do
    title = "I TRIED this for 30 DAYS?! [Ep. 2] 🔥"
    a = A.syntactic_attributes(title)
    assert a["has_question"]
    assert a["has_exclamation"]
    assert a["has_digit"]
    assert a["has_brackets_or_pipe"]
    assert a["has_emoji"]
    assert_equal false, a["caps_heavy"] # mixed case overall
    assert_equal title.length, a["length"]
  end

  test "caps heavy detection" do
    assert_equal true, A.syntactic_attributes("THIS IS ALL CAPS NEWS")["caps_heavy"]
    assert_equal false, A.syntactic_attributes("a normal lowercase title")["caps_heavy"]
  end

  test "content hash stable and title sensitive" do
    assert_equal A.title_content_hash("Same"), A.title_content_hash("Same")
    refute_equal A.title_content_hash("A"), A.title_content_hash("B")
  end

  def video(title:, youtube_video_id: "v1")
    ch = CompetitorChannel.create!(youtube_channel_id: "UCc0000000000000000000")
    ch.competitor_videos.create!(youtube_video_id:, title:)
  end

  test "refresh persists and is idempotent" do
    v = video(title: "Original title?")

    assert_equal 1, A.refresh_syntactic_attributes([ "v1" ])
    assert_equal true, v.video_attributes.find_by(source: A::SOURCE).attrs["has_question"]

    # Same title → no-op (content hash unchanged).
    assert_equal 0, A.refresh_syntactic_attributes([ "v1" ])

    # Changing the title triggers a single-row recompute (upserted, not duplicated).
    v.update!(title: "No question now")
    assert_equal 1, A.refresh_syntactic_attributes([ "v1" ])
    assert_equal 1, v.video_attributes.where(source: A::SOURCE).count
    assert_equal false, v.video_attributes.find_by(source: A::SOURCE).attrs["has_question"]
  end

  test "refresh skips unknown videos" do
    assert_equal 0, A.refresh_syntactic_attributes([ "nope" ])
  end
end
