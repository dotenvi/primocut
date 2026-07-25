require "test_helper"

# Tests for the pure packaging passes — faked LLM. Ported from the PoC
# `tests/test_packaging_generate.py`. Every pass VALIDATES the model's answer.
class Cuts::PackagingTest < ActiveSupport::TestCase
  Packaging = Cuts::Packaging

  class FakeLlm
    attr_reader :last

    def initialize(&block) = (@block = block)
    def select(**kwargs) = (@last = kwargs) && @block.call(kwargs)
  end

  def context
    {
      niche: { project_name: "Niche", channels: 2, outliers: 3, format: "long" },
      differential: [ { attribute: "has_face", source: "thumbnail_llm", freq_outlier: 0.8, freq_control: 0.3, lift: 2.6, verdict: "strong" } ],
      conventions: [], carries_value: {},
      examples: [ { video_id: "vid1", title: "Real Title", median_multiple: 3.2, title_attrs: {} } ],
      flat: false
    }
  end

  def clip = { title: "Opening", summary: "the intro", transcript_excerpt: "hello world" }

  test "content_hash is stable across key order and changes with the patterns" do
    a = Packaging.content_hash("title", clip, context, k: 5)
    b = Packaging.content_hash("title", clip, context, k: 5)
    assert_equal a, b

    moved = context.merge(differential: [])
    assert_not_equal a, Packaging.content_hash("title", clip, moved, k: 5)
  end

  test "generate_titles keeps at most K, recomputes length, drops unmatched citations" do
    llm = FakeLlm.new do
      { "titles" => [
        { "title" => "Great Clip", "length_chars" => 999,
          "patterns_applied" => [ { "kind" => "differential", "reference" => "D1" }, { "reference" => "Z9" } ], "rationale" => "fits" },
        { "title" => "  ", "patterns_applied" => [] }, # blank dropped
        { "title" => "Extra", "patterns_applied" => [] }
      ] }
    end
    out = Packaging.generate_titles(clip, context, 2, llm:)
    assert_equal 1, out["titles"].size # blank dropped, K=2 caps the raw list first
    t = out["titles"].first
    assert_equal "Great Clip".length, t["length_chars"] # recomputed, not 999
    assert_equal [ { "kind" => "differential", "reference" => "D1" } ], t["patterns_applied"] # Z9 dropped
  end

  test "generate_brief clamps references to real outlier examples" do
    llm = FakeLlm.new do
      { "composition" => {}, "references" => [ { "video_id" => "vid1", "why" => "ok" }, { "video_id" => "ghost", "why" => "no" } ] }
    end
    out = Packaging.generate_brief(clip, context, llm:)
    assert_equal [ "vid1" ], out["references"].map { |r| r["video_id"] }
    assert_equal false, out["flat"]
  end

  test "rank_frames clamps indices to real frames and falls back to the top score" do
    names = %w[frame-001.jpg frame-002.jpg]
    llm = FakeLlm.new do
      { "rankings" => [ { "frame" => 9, "score" => 0.9 }, { "frame" => 1, "score" => 0.4 } ], "best_frame" => 42 }
    end
    out = Packaging.rank_frames(names, nil, [ "a", "b" ], llm:)
    assert_equal [ 1, 1 ], out["rankings"].map { |r| r["frame"] } # 9 -> clamp 1
    assert_equal 1, out["best_frame"] # 42 clamps to a real frame; highest score is frame 1
    assert_equal "frame-002.jpg", out["best_filename"]
  end

  test "match_audience clamps topic ids and skips the LLM when empty" do
    called = false
    llm = FakeLlm.new { called = true; { "matches" => [] } }
    assert_equal({}, Packaging.match_audience([], [ { type: "guest", value: "x" } ], llm:))
    assert_equal({}, Packaging.match_audience([ { id: 1 } ], [], llm:))
    assert_not called, "no requests/topics means no model call"

    topics = [ { id: 7, title: "T" } ]
    requests = [ { type: "guest", value: "Ana" } ]
    llm2 = FakeLlm.new do
      { "matches" => [ { "topic_id" => 7, "request_type" => "guest", "request_value" => "Ana", "confidence" => "strong" },
                       { "topic_id" => 999, "request_value" => "ghost" } ] }
    end
    out = Packaging.match_audience(topics, requests, llm: llm2)
    assert_equal %w[7], out.keys
    assert_equal "Ana", out["7"].first["value"]
  end
end
