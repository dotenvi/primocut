require "test_helper"

class Cuts::SrtTest < ActiveSupport::TestCase
  Srt = Cuts::Srt

  def segs
    [
      { "start" => 0.0, "end" => 2.0, "text" => "before" },
      { "start" => 10.0, "end" => 12.5, "text" => "inside one" },
      { "start" => 13.0, "end" => 15.0, "text" => "inside two" },
      { "start" => 100.0, "end" => 101.0, "text" => "after" }
    ]
  end

  test "for_clip shifts to the clip time base and clamps to its length" do
    out = Srt.for_clip(segs, 10.0, 14.0)
    expected = <<~SRT
      1
      00:00:00,000 --> 00:00:02,500
      inside one

      2
      00:00:03,000 --> 00:00:04,000
      inside two
    SRT
    assert_equal expected, out
  end

  test "for_clip returns an empty string when nothing overlaps" do
    assert_equal "", Srt.for_clip(segs, 50.0, 60.0)
  end

  test "for_clip skips blank segments" do
    assert_equal "", Srt.for_clip([ { "start" => 1.0, "end" => 2.0, "text" => "  " } ], 0.0, 5.0)
  end

  test "ts is HH:MM:SS,mmm" do
    assert_equal "00:00:00,000", Srt.ts(0)
    assert_equal "01:02:03,500", Srt.ts(3723.5)
    assert_equal "00:00:00,000", Srt.ts(-5)
  end
end
