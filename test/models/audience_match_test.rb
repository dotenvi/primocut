require "test_helper"

class AudienceMatchTest < ActiveSupport::TestCase
  def setup
    project = Project.create!(name: "Niche")
    @video = project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
  end

  test "one match per source video, defaulting to done" do
    match = @video.create_audience_match!
    assert match.state_done?
    assert_raises(ActiveRecord::RecordNotUnique) do
      AudienceMatch.create!(source_video: @video)
    end
  end

  test "destroying the source video destroys the match" do
    @video.create_audience_match!
    assert_difference("AudienceMatch.count", -1) { @video.destroy }
  end
end
