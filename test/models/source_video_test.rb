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

  # Opening the room must not require having made a cut first, and opening it
  # twice must not leave two.
  test "active_cut creates the first cut lazily, then returns that same one" do
    v = @project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")

    first = assert_difference("Cut.count", 1) { v.active_cut }
    assert_no_difference("Cut.count") { assert_equal first, v.reload.active_cut }
  end

  test "active_cut is the oldest cut, whatever order they were asked for" do
    v = @project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    oldest = v.cuts.create!(name: "Cut 1", created_at: 2.days.ago)
    v.cuts.create!(name: "Cut 2", created_at: 1.day.ago)

    assert_equal oldest, v.active_cut
  end
end
