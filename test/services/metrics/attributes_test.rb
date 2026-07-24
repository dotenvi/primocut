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
end
