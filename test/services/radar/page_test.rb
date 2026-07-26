require "test_helper"

# The Radar pager's value object. The interesting behaviour is the clamp: a feed
# shrinks between requests, so a page number that no longer exists must land on
# the last page instead of rendering empty.
class Radar::PageTest < ActiveSupport::TestCase
  ROWS = (1..8).to_a

  test "slices the requested page and reports the pager state" do
    page = Radar::Page.new(ROWS, page: 2, per_page: 3)

    assert_equal [ 4, 5, 6 ], page.rows
    assert_equal 2, page.current
    assert_equal 3, page.total_pages
    assert_equal 8, page.total_count
    assert page.paged?
  end

  test "a page past the end clamps to the last one" do
    page = Radar::Page.new(ROWS, page: 99, per_page: 3)

    assert_equal 3, page.current
    assert_equal [ 7, 8 ], page.rows
  end

  test "a missing, zero or negative page reads as the first" do
    [ nil, 0, -5, "" ].each do |bad|
      assert_equal 1, Radar::Page.new(ROWS, page: bad, per_page: 3).current, "page: #{bad.inspect}"
    end
  end

  test "an empty feed is one page and never paged" do
    page = Radar::Page.new([], page: 1, per_page: 3)

    assert_empty page.rows
    assert_equal 1, page.total_pages
    assert_not page.any?
    assert_not page.paged?
  end

  test "a feed that fits in one page carries no pager" do
    assert_not Radar::Page.new(ROWS.first(3), page: 1, per_page: 3).paged?
  end
end
