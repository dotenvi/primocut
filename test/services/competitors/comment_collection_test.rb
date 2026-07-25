require "test_helper"

# Tests for the automatic comment collection (deterministic, no LLM). Covers the
# trigger (a video with an outlier_crossed event, and NOT one without), the
# page-dedup, collect-once, disabled degradation (terminal) and a fetch error
# (retried next cycle). Ported from the collection cases of the PoC
# `tests/test_comments.py`. Synthesis is an LLM pass and belongs to a later slice.
class Competitors::CommentCollectionTest < ActiveSupport::TestCase
  Api = Adapters::YoutubeApi
  NOW = Time.utc(2026, 7, 14, 12, 0, 0)

  # Duck-typed YoutubeApi: tracks quota and can fail/disable per video.
  class FakeYouTube
    attr_accessor :comments, :disabled, :boom
    attr_reader :comment_calls, :units_used

    def initialize
      @comments = {}      # video_id -> [CommentInfo]
      @disabled = Set.new
      @boom = Set.new     # video_id -> raise a transient error
      @comment_calls = []
      @units_used = 0
    end

    def list_top_comments(video_id, pages: 2)
      @comment_calls << [ video_id, pages ]
      raise Api::CommentsDisabledError, "comments are disabled on #{video_id}" if @disabled.include?(video_id)
      raise Api::Error, "transient-ish boom" if @boom.include?(video_id)

      @units_used += pages
      Array(@comments[video_id])
    end
  end

  def comment(i, likes, text) = Api::CommentInfo.new(comment_id: "c#{i}", text:, like_count: likes, author: "user#{i}")

  # A channel with a target video that HAS crossed the outlier threshold (an
  # outlier_crossed event already recorded), unless `crossed: false`.
  def seed(crossed: true)
    ch = CompetitorChannel.create!(youtube_channel_id: "UCc", uploads_playlist_id: "UUUCc")
    v = ch.competitor_videos.create!(youtube_video_id: "v1", title: "The outlier")
    if crossed
      Event.create!(
        category: "niche", event_type: "outlier_crossed", severity: "info",
        competitor_channel_id: ch.id, competitor_video_id: v.id, occurred_at: NOW, payload: { "band" => "relevant" }
      )
    end
    [ ch, v ]
  end

  def collect(channel, client, now: NOW)
    Competitors::CommentCollection.new(client:).call([ channel ], now:)
  end

  def stored(video) = video.video_comments.order(:comment_id).map { |c| [ c.comment_id, c.like_count ] }

  test "collects the top comments of a crossed video and marks it done" do
    ch, v = seed
    yt = FakeYouTube.new
    yt.comments["v1"] = [ comment(0, 500, "Melhor entrevista do ano"), comment(1, 300, "Traz o Fulano") ]

    assert_equal 1, collect(ch, yt)
    assert_equal [ "v1", 2 ], yt.comment_calls.sole
    assert_equal [ [ "c0", 500 ], [ "c1", 300 ] ], stored(v)
    v.reload
    assert_equal "done", v.comments_state
    assert_equal NOW, v.comments_fetched_at
  end

  test "a comment repeated across pages is de-duplicated" do
    ch, v = seed
    yt = FakeYouTube.new
    yt.comments["v1"] = [ comment(0, 500, "A"), comment(1, 300, "B"), comment(0, 500, "A") ] # page 2 repeated c0

    assert_equal 1, collect(ch, yt)
    assert_equal [ [ "c0", 500 ], [ "c1", 300 ] ], stored(v)
  end

  test "a video that never crossed is not collected" do
    ch, = seed(crossed: false)
    yt = FakeYouTube.new
    yt.comments["v1"] = [ comment(0, 500, "A") ]

    assert_equal 0, collect(ch, yt)
    assert_empty yt.comment_calls
  end

  test "collect-once: a second run does not re-fetch a done outlier" do
    ch, = seed
    yt = FakeYouTube.new
    yt.comments["v1"] = [ comment(0, 500, "A") ]

    collect(ch, yt)
    collect(ch, yt)
    assert_equal 1, yt.comment_calls.size # done is terminal
  end

  test "disabled comments degrade to a terminal state" do
    ch, v = seed
    yt = FakeYouTube.new
    yt.disabled << "v1"

    assert_equal 0, collect(ch, yt)
    assert_equal "disabled", v.reload.comments_state

    collect(ch, yt)
    assert_equal 1, yt.comment_calls.size # disabled is terminal — never asked again
  end

  test "a fetch error is recorded and retried next cycle" do
    ch, v = seed
    yt = FakeYouTube.new
    yt.boom << "v1"
    yt.comments["v1"] = [ comment(0, 500, "A"), comment(1, 300, "B") ]

    assert_equal 0, collect(ch, yt)
    v.reload
    assert_equal "error", v.comments_state
    assert v.comments_error.present?

    # "error" is NOT terminal — the next cycle retries and succeeds.
    yt.boom.delete("v1")
    assert_equal 1, collect(ch, yt)
    assert_equal [ [ "c0", 500 ], [ "c1", 300 ] ], stored(v)
    assert_equal "done", v.reload.comments_state
  end

  test "collection never synthesises" do
    ch, v = seed
    yt = FakeYouTube.new
    yt.comments["v1"] = [ comment(0, 500, "A") ]

    collect(ch, yt)
    assert v.video_comments.any?              # comments WERE collected (deterministic)
    assert_equal 0, v.video_enrichments.count # ...and nothing was ever synthesised
  end
end
