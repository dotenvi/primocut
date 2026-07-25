require "test_helper"

class TopicTriageTest < ActiveSupport::TestCase
  def setup
    project = Project.create!(name: "Niche")
    @video = project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    @topic = @video.topics.create!(title: "Opening")
  end

  test "one opinion per (source video, topic)" do
    @video.topic_triages.create!(topic: @topic, state: "maybe")
    dup = TopicTriage.new(source_video: @video, topic: @topic, state: "discarded")
    assert_not dup.valid?
  end

  test "state is limited to maybe/discarded" do
    tt = @video.topic_triages.create!(topic: @topic, state: "maybe")
    assert tt.state_maybe?
    assert_raises(ArgumentError) { tt.update!(state: "in") }
  end

  test "regenerating a topic drops its opinion" do
    @video.topic_triages.create!(topic: @topic, state: "discarded")
    assert_difference("TopicTriage.count", -1) { @topic.destroy }
  end
end
