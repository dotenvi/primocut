require "test_helper"

# Tests for the topic selection — faked LLM (no network). Ported from the PoC
# `tests/test_topics.py` + `tests/test_analysis_runner.py`.
class Cuts::SelectionTest < ActiveSupport::TestCase
  # Returns a canned payload per call; can be told to raise (permanent failure).
  class FakeLlm
    def initialize(payloads: [], raise_after: nil)
      @payloads = payloads
      @raise_after = raise_after
      @calls = 0
    end

    def select(system:, user:, schema:)
      @calls += 1
      raise "no credit" if @raise_after && @calls > @raise_after

      @payloads[@calls - 1] || { "topics" => [] }
    end
  end

  def setup
    project = Project.create!(name: "Niche")
    @video = project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1", duration_s: 60)
    @video.create_transcript!(language: "pt", model: "m", segments: seg_rows)
  end

  def seg_rows
    (0...6).map { |i| { "index" => i, "start" => i * 10.0, "end" => i * 10.0 + 10.0, "text" => "s#{i}" } }
  end

  def topic(title, si, ei, score)
    { "title" => title, "summary" => "#{title} summary", "start_index" => si, "end_index" => ei, "score" => score }
  end

  test "extract resolves indices to seconds and consolidates" do
    llm = FakeLlm.new(payloads: [ { "topics" => [ topic("Intro", 0, 1, 0.8), topic("Deep", 3, 5, 0.6) ] } ])
    sel = Cuts::Selection.new(llm:, target_seconds: 600, overlap_seconds: 60)

    cands = sel.extract(seg_rows)
    assert_equal [ "Intro", "Deep" ], cands.map(&:title)
    assert_equal [ 0.0, 20.0 ], [ cands.first.start_s, cands.first.end_s ]
    assert_equal [ 30.0, 60.0 ], [ cands.last.start_s, cands.last.end_s ]
  end

  test "call persists topics with ordinals and replaces the previous set" do
    old = @video.topics.create!(title: "Stale", start_s: 0, end_s: 1)
    @video.topic_triages.create!(topic: old, state: "maybe")

    llm = FakeLlm.new(payloads: [ { "topics" => [ topic("Fresh", 0, 2, 0.7) ] } ])
    rows = Cuts::Selection.new(llm:, target_seconds: 600, overlap_seconds: 60).call(@video)

    assert_equal [ "Fresh" ], @video.reload.topics.ordered.map(&:title)
    assert_equal 0, rows.first.ordinal
    assert_equal 0, TopicTriage.where(topic_id: old.id).count, "regeneration drops the old triage"
  end

  test "a permanent LLM failure ends the pass with the partial plus a warning" do
    # window 1 succeeds, window 2 raises → only window 1's topics survive.
    llm = FakeLlm.new(payloads: [ { "topics" => [ topic("Kept", 0, 1, 0.9) ] } ], raise_after: 1)
    sel = Cuts::Selection.new(llm:, target_seconds: 30, overlap_seconds: 10)
    warnings = []

    cands = sel.extract(seg_rows, warnings:)
    assert_equal [ "Kept" ], cands.map(&:title)
    assert_equal 1, warnings.size
    assert_match(/stopped at window/, warnings.first)
  end

  test "malformed items are skipped, valid ones kept" do
    payload = { "topics" => [ topic("Good", 0, 1, 0.5), { "title" => "NoIndices" }, "not-an-object" ] }
    llm = FakeLlm.new(payloads: [ payload ])
    cands = Cuts::Selection.new(llm:, target_seconds: 600, overlap_seconds: 60).extract(seg_rows)
    assert_equal [ "Good" ], cands.map(&:title)
  end
end
