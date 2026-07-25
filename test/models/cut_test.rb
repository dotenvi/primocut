require "test_helper"

class CutTest < ActiveSupport::TestCase
  def setup
    project = Project.create!(name: "Niche")
    @video = project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
  end

  test "defaults to draft and requires a name" do
    cut = @video.cuts.create!
    assert cut.status_draft?
    assert_equal "Cut 1", cut.name

    cut.name = ""
    assert_not cut.valid?
  end

  test "cut_items come back ordered by position" do
    cut = @video.cuts.create!
    second = cut.cut_items.create!(position: 1, start_s: 10, end_s: 20)
    first = cut.cut_items.create!(position: 0, start_s: 0, end_s: 5)
    assert_equal [ first, second ], cut.cut_items.to_a
  end

  test "destroying the cut destroys its items and export" do
    cut = @video.cuts.create!
    cut.cut_items.create!(position: 0, start_s: 0, end_s: 5)
    cut.create_export!(source_video_id: @video.id)
    assert_difference([ "CutItem.count", "Export.count" ], -1) { cut.destroy }
  end
end
