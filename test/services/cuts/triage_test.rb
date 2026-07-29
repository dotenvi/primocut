require "test_helper"

class Cuts::TriageTest < ActiveSupport::TestCase
  def setup
    project = Project.create!(name: "Niche")
    @video = project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    @topic = @video.topics.create!(title: "Opening")
  end

  def triage(state, topic_id: @topic.id, source_video: @video)
    Cuts::Triage.new.call(source_video:, topic_id:, state:)
  end

  test "set records maybe/discarded and is idempotent per (video, topic)" do
    triage("maybe")
    triage("discarded")
    assert_equal 1, TopicTriage.count
    assert TopicTriage.first.state_discarded?
  end

  test "setting open clears the opinion" do
    triage("maybe")
    assert_nil triage("open")
    assert_equal 0, TopicTriage.count
  end

  test "a nil state clears the opinion too" do
    triage("discarded")
    assert_nil triage(nil)
    assert_equal 0, TopicTriage.count
  end

  # The guard the controller used to hold: the topic is resolved off the source
  # video, so an id from another video cannot be triaged onto this one.
  test "a topic from another source video is not found" do
    other = Project.create!(name: "Other").source_videos.create!(youtube_id: "zzzzzzzzzzz", url: "https://y/2")
    theirs = other.topics.create!(title: "Theirs")

    assert_raises(ActiveRecord::RecordNotFound) { triage("maybe", topic_id: theirs.id) }
    assert_equal 0, TopicTriage.count
  end
end
