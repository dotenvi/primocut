require "test_helper"

class Cuts::WindowingTest < ActiveSupport::TestCase
  Windowing = Cuts::Windowing

  # 6 segments, one every 10s, spanning [0, 60).
  def segs
    (0...6).map { |i| { "index" => i, "start" => i * 10.0, "end" => i * 10.0 + 10.0, "text" => "s#{i}" } }
  end

  test "empty segments yield no windows" do
    assert_empty Windowing.make([], target_seconds: 30, overlap_seconds: 5)
  end

  test "a target covering everything is a single window" do
    windows = Windowing.make(segs, target_seconds: 600, overlap_seconds: 60)
    assert_equal 1, windows.size
    assert_equal 0, windows.first.start_index
    assert_equal 5, windows.first.end_index
  end

  test "windows slide by (target - overlap) and keep global indices" do
    windows = Windowing.make(segs, target_seconds: 30, overlap_seconds: 10)
    # step = 20 → window starts at 0,20,40. [0,30):0-2  [20,50):2-4  [40,70):4-5
    assert_equal [ [ 0, 2 ], [ 2, 4 ], [ 4, 5 ] ], windows.map { |w| [ w.start_index, w.end_index ] }
  end

  test "indexed_text renders [i] M:SS text" do
    windows = Windowing.make(segs, target_seconds: 8, overlap_seconds: 0)
    assert_equal "[0] 0:00 s0", windows.first.indexed_text
  end
end
