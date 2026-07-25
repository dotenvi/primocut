require "test_helper"

class CutItemTest < ActiveSupport::TestCase
  def setup
    project = Project.create!(name: "Niche")
    @video = project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    @cut = @video.cuts.create!
    @topic = @video.topics.create!(title: "Opening", start_s: 0, end_s: 30)
  end

  test "a manual range has no topic" do
    item = @cut.cut_items.create!(position: 0, start_s: 5, end_s: 15)
    assert item.manual_range?
  end

  test "a topic item carries its topic" do
    item = @cut.cut_items.create!(position: 0, topic: @topic, start_s: 0, end_s: 30)
    assert_not item.manual_range?
  end

  test "deleting the topic degrades the item to a preserved manual range" do
    item = @cut.cut_items.create!(position: 0, topic: @topic, start_s: 0, end_s: 30)
    @topic.destroy
    item.reload
    assert_nil item.topic_id
    assert item.manual_range?
    assert_equal 0.0, item.start_s
    assert_equal 30.0, item.end_s
  end
end
