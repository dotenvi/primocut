require "test_helper"

# Tests for the pure comment-synthesis helpers: the set-based content hash, the
# spelling-normalising request key, the clamped quote resolution (the model returns
# an index, never text), the defensive payload build, and the project-level request
# aggregation. Ported from the PoC `tests/test_comments.py`.
class Competitors::CommentSynthesisTest < ActiveSupport::TestCase
  C = Competitors::CommentSynthesis
  Comment = Struct.new(:comment_id, :text, :like_count, :author, keyword_init: true)

  def comments
    [
      Comment.new(comment_id: "c0", text: "Melhor entrevista do ano, muito honesta", like_count: 500, author: "user0"),
      Comment.new(comment_id: "c1", text: "Traz o Fulano de Tal, por favor", like_count: 300, author: "user1")
    ]
  end

  test "content hash depends on the set, not the order, but tracks likes" do
    assert_equal C.content_hash(comments), C.content_hash(comments.reverse)

    changed = comments
    changed[0].like_count = 999
    refute_equal C.content_hash(comments), C.content_hash(changed)
  end

  test "request_key normalises spelling variants" do
    assert_equal C.request_key("Fulano de Tal"), C.request_key("  fulano  de tal!  ")
    assert_equal "economia", C.request_key("Economia?")
  end

  test "resolve_example clamps an out-of-range or non-integer index" do
    cs = comments
    assert_equal "c1", C.resolve_example(cs, 99)["comment_id"]     # clamped to the last
    assert_equal "c0", C.resolve_example(cs, -5)["comment_id"]     # clamped to the first
    assert_equal "c0", C.resolve_example(cs, "nope")["comment_id"] # non-integer → 0
    assert_equal({}, C.resolve_example([], 0))
  end

  test "build_payload resolves indices, keys requests, and drops empty values" do
    raw = {
      "themes" => [ { "theme" => "honestidade", "mentions" => 12, "example_index" => 0 } ],
      "requests" => [
        { "type" => "guest", "value" => "Fulano de Tal", "mentions" => 9, "example_index" => 1 },
        { "type" => "guest", "value" => "  ", "mentions" => 1, "example_index" => 0 } # empty value → dropped
      ],
      "sentiment" => "positive", "sentiment_note" => "Loved it."
    }

    payload = C.build_payload(raw, comments)
    assert_equal "c0", payload["themes"][0]["example"]["comment_id"]
    assert_equal 1, payload["requests"].size
    assert_equal "fulano de tal", payload["requests"][0]["value_key"]
    assert_equal "c1", payload["requests"][0]["example"]["comment_id"]
    assert_equal "positive", payload["sentiment"]
    assert_equal 2, payload["comments_analysed"]
  end

  test "build_payload degrades an unknown request type and sentiment" do
    payload = C.build_payload(
      { "requests" => [ { "type" => "weird", "value" => "X", "mentions" => 1, "example_index" => 0 } ], "sentiment" => "furious" },
      comments
    )
    assert_equal "other", payload["requests"][0]["type"]
    assert_equal "neutral", payload["sentiment"]
  end

  test "aggregate_requests merges spelling variants and ranks by videos then mentions" do
    a = { "requests" => [
      { "type" => "guest", "value" => "Fulano de Tal", "value_key" => C.request_key("Fulano de Tal"), "mentions" => 5 },
      { "type" => "topic", "value" => "Economia", "value_key" => C.request_key("Economia"), "mentions" => 2 }
    ] }
    b = { "requests" => [ { "type" => "guest", "value" => "  fulano de tal!  ", "value_key" => C.request_key("  fulano de tal!  "), "mentions" => 5 } ] }

    agg = C.aggregate_requests([ [ "vA", a ], [ "vB", b ] ])

    assert_equal 2, agg["videos_synthesised"]
    guests = agg["by_type"]["guest"]
    assert_equal 1, guests.size
    assert_equal 2, guests[0]["videos"]   # merged despite the spelling difference
    assert_equal 10, guests[0]["mentions"]
    assert_equal %w[vA vB], guests[0]["video_ids"]
    assert_equal "Fulano de Tal", guests[0]["value"] # the raw spelling, not the key
    assert_equal "Economia", agg["by_type"]["topic"][0]["value"]
  end
end
