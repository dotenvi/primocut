require "test_helper"

# Tests for the opt-in title enrichment with the LLM fully faked (no network).
# Covers the content-hash cache (paid once, re-run is free), re-enrichment on a
# title change, the derived boolean facets, per-video error isolation with a hash
# reset for retry, an unknown video, and an unknown kind (a caller bug).
class Enrichment::VideoEnricherTest < ActiveSupport::TestCase
  RAW = { "person_names" => [ "Fulano" ], "topic" => "rivalidade", "tone" => "drama", "quoted_speech" => "" }.freeze

  # A fake SelectionLlm: counts calls and returns a canned payload (or raises).
  class FakeLLM
    attr_reader :calls

    def initialize(raw: nil, boom: false)
      @raw = raw
      @boom = boom
      @calls = 0
    end

    def select(system:, user:, schema:, image: nil, model: nil)
      @calls += 1
      raise "llm boom" if @boom

      @raw
    end
  end

  def video(title: "Fulano DETONA o rival?!", youtube_video_id: "v1")
    ch = CompetitorChannel.find_or_create_by!(youtube_channel_id: "UCc")
    ch.competitor_videos.create!(youtube_video_id:, title:)
  end

  def video_with_thumb(hash: "bytehash123", url: "https://i.ytimg.com/vi/v1/hq.jpg")
    video.tap { |v| v.update!(thumbnail_hash: hash, thumbnail_url: url) }
  end

  THUMB_RAW = {
    "face_count" => 2, "dominant_expression" => "shock", "has_text" => true,
    "text_word_count" => 5, "text" => "OLHA ISSO", "dominant_colors" => [ "red", "black" ],
    "contrast" => "high", "has_arrow" => true, "has_circle_or_highlight" => false,
    "is_confrontation_framing" => true
  }.freeze

  def enricher(llm) = Enrichment::VideoEnricher.new(llm:)

  test "enriches the title and stores the raw output merged with derived facets" do
    v = video
    llm = FakeLLM.new(raw: RAW)

    assert_equal :enriched, enricher(llm).call("v1", kind: "title")

    row = v.video_attributes.find_by(source: "title_llm")
    assert row.state_done?
    assert_equal "drama", row.attrs["tone"]                 # raw output
    assert_equal true, row.attrs["title_has_person_name"]   # derived facet
    assert_equal false, row.attrs["title_multiple_people"]
    assert_equal true, row.attrs["title_tone_drama"]
    assert_equal false, row.attrs["title_tone_hype"]
    assert row.content_hash.present?
  end

  test "a second run with the same title is a free cache hit" do
    video
    llm = FakeLLM.new(raw: RAW)
    e = enricher(llm)

    e.call("v1", kind: "title")
    assert_equal :cached, e.call("v1", kind: "title")
    assert_equal 1, llm.calls # never recharged
  end

  test "a title change re-enriches" do
    v = video
    llm = FakeLLM.new(raw: RAW)
    e = enricher(llm)

    e.call("v1", kind: "title")
    v.update!(title: "Outro título completamente diferente")
    assert_equal :enriched, e.call("v1", kind: "title")
    assert_equal 2, llm.calls
  end

  test "an LLM failure is isolated and clears the hash for retry" do
    v = video

    assert_equal :failed, enricher(FakeLLM.new(boom: true)).call("v1", kind: "title")

    row = v.video_attributes.find_by(source: "title_llm")
    assert row.state_error?
    assert_equal "", row.content_hash # cleared → the next click retries
    assert row.error.present?
  end

  test "an unknown video does not crash" do
    assert_equal :failed, enricher(FakeLLM.new(raw: RAW)).call("nope", kind: "title")
  end

  test "an unknown kind is a caller bug, not a per-video failure" do
    video
    assert_raises(Enrichment::VideoEnricher::UnknownKind) do
      enricher(FakeLLM.new(raw: RAW)).call("v1", kind: "bogus")
    end
  end

  # ------------------------- thumbnail (vision) -------------------------

  test "enriches the thumbnail via vision and stores raw output plus facets" do
    v = video_with_thumb
    llm = FakeLLM.new(raw: THUMB_RAW)
    fetched = nil
    fetcher = ->(url) { fetched = url; "IMG".b }
    e = Enrichment::VideoEnricher.new(llm:, thumbnail_fetcher: fetcher)

    assert_equal :enriched, e.call("v1", kind: "thumbnail")
    assert_equal "https://i.ytimg.com/vi/v1/hq.jpg", fetched # fetched from the stored URL

    row = v.video_attributes.find_by(source: "thumbnail_llm")
    assert row.state_done?
    assert_equal "shock", row.attrs["dominant_expression"]  # raw output
    assert_equal true, row.attrs["thumb_multiple_faces"]    # facet: 2 >= 2
    assert_equal true, row.attrs["thumb_text_heavy"]        # facet: 5 >= 4
    assert_equal true, row.attrs["thumb_color_red"]
    assert_equal false, row.attrs["thumb_color_blue"]
    assert_equal true, row.attrs["thumb_expression_shock"]
    assert_equal false, row.attrs["thumb_has_circle"]
    assert_equal "bytehash123", row.content_hash            # keyed by the byte hash
  end

  test "the thumbnail is cached by the byte hash (no re-fetch, no LLM call)" do
    video_with_thumb
    llm = FakeLLM.new(raw: THUMB_RAW)
    e = Enrichment::VideoEnricher.new(llm:, thumbnail_fetcher: ->(_url) { "IMG".b })

    e.call("v1", kind: "thumbnail")
    assert_equal :cached, e.call("v1", kind: "thumbnail")
    assert_equal 1, llm.calls
  end

  test "a thumbnail with no byte hash yet is refused with a visible error" do
    v = video # thumbnail_hash defaults to ""
    e = Enrichment::VideoEnricher.new(llm: FakeLLM.new(raw: THUMB_RAW), thumbnail_fetcher: ->(_url) { "IMG".b })

    assert_equal :failed, e.call("v1", kind: "thumbnail")
    row = v.video_attributes.find_by(source: "thumbnail_llm")
    assert row.state_error?
    assert_includes row.error, "hashed"
  end

  # ------------------------- comments (synthesis) -------------------------

  SYNTH_RAW = {
    "themes" => [ { "theme" => "honestidade", "mentions" => 12, "example_index" => 0 } ],
    "requests" => [ { "type" => "guest", "value" => "Fulano de Tal", "mentions" => 9, "example_index" => 1 } ],
    "sentiment" => "positive", "sentiment_note" => "Loved it."
  }.freeze

  def video_with_comments
    v = video
    v.video_comments.create!(comment_id: "c0", text: "Melhor entrevista do ano", like_count: 500, author: "u0", fetched_at: Time.current)
    v.video_comments.create!(comment_id: "c1", text: "Traz o Fulano de Tal", like_count: 300, author: "u1", fetched_at: Time.current)
    v
  end

  test "synthesises comments into video_enrichments with quotes resolved from the store" do
    v = video_with_comments

    assert_equal :enriched, enricher(FakeLLM.new(raw: SYNTH_RAW)).call("v1", kind: "comments")

    row = v.video_enrichments.find_by(kind: Enrichment::Comments::KIND)
    assert row.state_done?
    assert_equal "positive", row.payload["sentiment"]
    assert_equal "c0", row.payload["themes"][0]["example"]["comment_id"]    # resolved from index 0
    assert_equal "c1", row.payload["requests"][0]["example"]["comment_id"]  # index 1
    assert_equal "fulano de tal", row.payload["requests"][0]["value_key"]
    assert_equal 2, row.payload["comments_analysed"]
    assert row.content_hash.present?
  end

  test "the synthesis is cached by the comment-set hash" do
    video_with_comments
    llm = FakeLLM.new(raw: SYNTH_RAW)
    e = enricher(llm)

    e.call("v1", kind: "comments")
    assert_equal :cached, e.call("v1", kind: "comments")
    assert_equal 1, llm.calls
  end

  test "a video with no comments is refused with a visible reason" do
    v = video # no comments collected

    assert_equal :failed, enricher(FakeLLM.new(raw: SYNTH_RAW)).call("v1", kind: "comments")

    row = v.video_enrichments.find_by(kind: Enrichment::Comments::KIND)
    assert row.state_error?
    assert_includes row.error, "collected"
  end

  test "regenerate re-collects the comments before synthesising" do
    video_with_comments
    recollected = nil
    recollector = ->(video) { recollected = video.youtube_video_id }
    e = Enrichment::VideoEnricher.new(llm: FakeLLM.new(raw: SYNTH_RAW), comment_recollector: recollector)

    assert_equal :enriched, e.call("v1", kind: "comments", regenerate: true)
    assert_equal "v1", recollected
  end

  test "regenerate is rejected for a packaging kind (a caller bug)" do
    video
    assert_raises(Enrichment::VideoEnricher::RegenerateNotAllowed) do
      enricher(FakeLLM.new(raw: RAW)).call("v1", kind: "title", regenerate: true)
    end
  end
end
