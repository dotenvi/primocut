require "test_helper"

class TopicTest < ActiveSupport::TestCase
  def setup
    project = Project.create!(name: "Niche")
    @video = project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
  end

  test "belongs to a source video and requires a title" do
    t = Topic.new(source_video: @video)
    assert_not t.valid?
    t.title = "Opening"
    assert t.valid?
  end

  test "ordered scope sorts by ordinal" do
    c = @video.topics.create!(title: "C", ordinal: 2)
    a = @video.topics.create!(title: "A", ordinal: 0)
    b = @video.topics.create!(title: "B", ordinal: 1)
    assert_equal [ a, b, c ], @video.topics.ordered.to_a
  end

  test "destroying the source video destroys its topics" do
    @video.topics.create!(title: "Opening")
    assert_difference("Topic.count", -1) { @video.destroy }
  end
end
