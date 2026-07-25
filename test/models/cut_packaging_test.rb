require "test_helper"

class CutPackagingTest < ActiveSupport::TestCase
  def setup
    project = Project.create!(name: "Niche")
    @video = project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    @cut = @video.cuts.create!
    @item = @cut.cut_items.create!(position: 0, start_s: 0, end_s: 10)
  end

  test "kind is limited to the known taxonomy" do
    pk = @item.cut_packagings.new(cut_id: @cut.id, kind: "bogus")
    assert_not pk.valid?
    pk.kind = "title"
    assert pk.valid?
  end

  test "one packaging per (cut item, kind), defaulting to done" do
    @item.cut_packagings.create!(cut_id: @cut.id, kind: "title")
    dup = @item.cut_packagings.new(cut_id: @cut.id, kind: "title")
    assert_not dup.valid?

    other = @item.cut_packagings.create!(cut_id: @cut.id, kind: "thumb_brief")
    assert other.state_done?
  end
end
