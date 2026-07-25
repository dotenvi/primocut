require "test_helper"

class Cuts::ConsolidateTest < ActiveSupport::TestCase
  Candidate = Cuts::Selection::Candidate

  def cand(start_s, end_s, score, title = "t")
    Candidate.new(title:, summary: "", start_s:, end_s:, score:)
  end

  test "merges window-overlap duplicates, keeping the higher score and the union" do
    a = cand(0, 100, 0.4, "low")
    b = cand(5, 105, 0.9, "high") # ~95% overlap of the shorter → duplicate
    merged = Cuts::Consolidate.merge_overlapping([ a, b ])
    assert_equal 1, merged.size
    assert_equal "high", merged.first.title
    assert_equal [ 0.0, 105.0 ], [ merged.first.start_s, merged.first.end_s ]
  end

  test "keeps distinct adjacent subjects that barely touch" do
    a = cand(0, 100, 0.5)
    b = cand(95, 200, 0.5) # only 5s overlap of a 100s span → distinct
    assert_equal 2, Cuts::Consolidate.merge_overlapping([ a, b ]).size
  end

  test "returns chronological order and handles the empty case" do
    assert_empty Cuts::Consolidate.merge_overlapping([])
    out = Cuts::Consolidate.merge_overlapping([ cand(50, 60, 0.1), cand(0, 10, 0.1) ])
    assert_equal [ 0.0, 50.0 ], out.map(&:start_s)
  end
end
