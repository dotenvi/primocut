require "test_helper"

# Accepting a link. The identity is the YouTube id, not the url, so the same
# video pasted in two forms is one row — and one queue slot.
class Sources::SubmitTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup { @project = Project.create!(name: "Chess") }

  def submit(url) = Sources::Submit.new.call(project: @project, url: url)

  test "canonicalises the link and queues the pipeline" do
    video = nil
    assert_enqueued_with(job: SourceVideoPipelineJob) { video = submit("https://youtu.be/abcdefghijk") }

    assert_equal "abcdefghijk", video.youtube_id
    assert_equal "https://www.youtube.com/watch?v=abcdefghijk", video.url
    assert video.queued?
  end

  test "the same video in another url form is one row, not two" do
    submit("https://youtu.be/abcdefghijk")
    submit("https://www.youtube.com/watch?v=abcdefghijk")

    assert_equal 1, @project.source_videos.count
  end

  test "re-submitting a settled video queues it again" do
    video = submit("https://youtu.be/abcdefghijk")
    video.update!(status: "error")

    assert_enqueued_with(job: SourceVideoPipelineJob) { submit("https://youtu.be/abcdefghijk") }
    assert video.reload.queued?
  end

  test "a link that is not YouTube is refused without writing or queueing" do
    assert_no_enqueued_jobs do
      assert_no_difference -> { SourceVideo.count } do
        assert_raises(Sources::Submit::Failed) { submit("https://vimeo.com/123") }
      end
    end
  end

  test "a blank link is refused" do
    assert_raises(Sources::Submit::Failed) { submit("") }
  end

  test "a video another project already holds is refused, with the reason" do
    # `youtube_id` is globally unique, so a source belongs to exactly one project.
    # The rejection has to say so rather than surface a raw database error.
    submit("https://youtu.be/abcdefghijk")
    other = Project.create!(name: "Poker")

    error = assert_raises(Sources::Submit::Failed) do
      Sources::Submit.new.call(project: other, url: "https://youtu.be/abcdefghijk")
    end

    assert_match(/already been taken/i, error.message)
    assert_equal 0, other.source_videos.count
  end
end
