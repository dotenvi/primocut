require "test_helper"

class SourceVideoTest < ActiveSupport::TestCase
  def setup
    @project = Project.create!(name: "Niche")
  end

  test "youtube_id is required and unique" do
    @project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    dup = SourceVideo.new(project: @project, youtube_id: "abcdefghijk", url: "https://y/2")
    assert_not dup.valid?
  end

  test "url is required" do
    v = SourceVideo.new(project: @project, youtube_id: "abcdefghijk")
    assert_not v.valid?
  end

  test "defaults to queued" do
    v = @project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    assert_equal "queued", v.status
    assert v.queued?
  end

  test "active? covers the in-flight statuses only" do
    v = @project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    SourceVideo::ACTIVE_STATUSES.each do |s|
      v.update!(status: s)
      assert v.active?, "#{s} should be active"
    end
    %w[done error stopped].each do |s|
      v.update!(status: s)
      assert_not v.active?, "#{s} should not be active"
    end
  end

  test "active scope returns only in-flight rows" do
    a = @project.source_videos.create!(youtube_id: "aaaaaaaaaaa", url: "https://y/a", status: "transcribing")
    @project.source_videos.create!(youtube_id: "bbbbbbbbbbb", url: "https://y/b", status: "done")
    assert_equal [ a ], SourceVideo.active.to_a
  end
end
