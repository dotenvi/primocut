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

    def select(system:, user:, schema:, model: nil)
      @calls += 1
      raise "llm boom" if @boom

      @raw
    end
  end

  def video(title: "Fulano DETONA o rival?!", youtube_video_id: "v1")
    ch = CompetitorChannel.find_or_create_by!(youtube_channel_id: "UCc")
    ch.competitor_videos.create!(youtube_video_id:, title:)
  end

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
      enricher(FakeLLM.new(raw: RAW)).call("v1", kind: "thumbnail")
    end
  end
end
