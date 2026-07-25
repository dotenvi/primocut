require "test_helper"

class Cuts::SpanResolverTest < ActiveSupport::TestCase
  def segs
    [
      { "index" => 0, "start" => 0.0, "end" => 5.0, "text" => "a" },
      { "index" => 1, "start" => 5.0, "end" => 10.0, "text" => "b" },
      { "index" => 2, "start" => 10.0, "end" => 15.0, "text" => "c" }
    ]
  end

  test "resolves an index span to real seconds" do
    assert_equal [ 0.0, 10.0 ], Cuts::SpanResolver.new(segs).resolve(0, 1)
    assert_equal [ 5.0, 15.0 ], Cuts::SpanResolver.new(segs).resolve(1, 2)
  end

  test "clamps out-of-range and sorts a reversed pair" do
    r = Cuts::SpanResolver.new(segs)
    assert_equal [ 0.0, 15.0 ], r.resolve(-4, 99)
    assert_equal [ 0.0, 10.0 ], r.resolve(1, 0) # reversed
  end

  test "empty transcript resolves to zero" do
    assert_equal [ 0.0, 0.0 ], Cuts::SpanResolver.new([]).resolve(0, 3)
  end
end
