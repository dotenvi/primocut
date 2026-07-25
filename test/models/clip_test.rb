require "test_helper"

class ClipTest < ActiveSupport::TestCase
  def setup
    project = Project.create!(name: "Niche")
    @video = project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    @cut = @video.cuts.create!
    @item = @cut.cut_items.create!(position: 0, start_s: 0, end_s: 10)
  end

  def build_clip(**overrides)
    @item.build_clip({ source_video_id: @video.id, cut_id: @cut.id }.merge(overrides))
  end

  test "defaults to queued and walks the render states" do
    clip = build_clip
    clip.save!
    assert clip.state_queued?
    %w[downloading_section aligning cutting done error].each do |s|
      clip.update!(state: s)
      assert_equal s, clip.state
    end
  end

  test "one clip per cut item" do
    build_clip.save!
    assert_raises(ActiveRecord::RecordNotUnique) do
      Clip.create!(cut_item: @item, source_video_id: @video.id, cut_id: @cut.id)
    end
  end

  test "removing the cut item destroys its clip" do
    build_clip.save!
    assert_difference("Clip.count", -1) { @item.destroy }
  end
end
