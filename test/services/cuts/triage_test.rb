require "test_helper"

class Cuts::TriageTest < ActiveSupport::TestCase
  def setup
    project = Project.create!(name: "Niche")
    @video = project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    @topic = @video.topics.create!(title: "Opening")
  end

  test "set records maybe/discarded and is idempotent per (video, topic)" do
    Cuts::Triage.set(@video, @topic, "maybe")
    Cuts::Triage.set(@video, @topic, "discarded")
    assert_equal 1, TopicTriage.count
    assert TopicTriage.first.state_discarded?
  end

  test "setting open clears the opinion" do
    Cuts::Triage.set(@video, @topic, "maybe")
    assert_nil Cuts::Triage.set(@video, @topic, "open")
    assert_equal 0, TopicTriage.count
  end

  test "clear removes the row" do
    Cuts::Triage.set(@video, @topic, "discarded")
    Cuts::Triage.clear(@video, @topic)
    assert_equal 0, TopicTriage.count
  end
end
