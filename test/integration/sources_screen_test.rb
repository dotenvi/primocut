require "test_helper"

# The Sources screen: submit a YouTube link (validated, enqueues the pipeline),
# list the project's source videos, and poll one row for live progress. Scoped to
# the project (leakage guard).
class SourcesScreenTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @project = Project.create!(name: "Chess")
  end

  test "renders the submit form and lists source videos" do
    @project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1", title: "A Live", status: "done")

    get project_sources_path(@project)

    assert_response :success
    assert_select "form[action=?]", project_sources_path(@project)
    assert_select "turbo-frame#source_video_#{SourceVideo.last.id}", text: /A Live/
  end

  test "submitting a valid link creates a source video and enqueues the pipeline" do
    assert_enqueued_with(job: SourceVideoPipelineJob) do
      post project_sources_path(@project), params: { source_video: { url: "https://youtu.be/abcdefghijk" } }
    end

    assert_redirected_to project_sources_path(@project)
    sv = @project.source_videos.find_by(youtube_id: "abcdefghijk")
    assert sv.present?
    assert_equal "https://www.youtube.com/watch?v=abcdefghijk", sv.url
    assert sv.queued?
  end

  test "an invalid link is rejected without creating anything" do
    assert_no_enqueued_jobs do
      assert_no_difference -> { SourceVideo.count } do
        post project_sources_path(@project), params: { source_video: { url: "https://vimeo.com/123" } }
      end
    end

    assert_response :unprocessable_entity
    assert_select ".text-err"
  end

  test "an in-flight row carries the polling frame; a terminal row does not" do
    active = @project.source_videos.create!(youtube_id: "aaaaaaaaaaa", url: "https://y/a", status: "transcribing")
    active.pipeline_jobs.create!(status: "started", stage: "Transcription", progress: 30)
    @project.source_videos.create!(youtube_id: "bbbbbbbbbbb", url: "https://y/b", status: "done")

    get project_sources_path(@project)

    assert_select "turbo-frame#source_video_#{active.id}[src][data-controller=?]", "poll"
    assert_select "turbo-frame#source_video_#{SourceVideo.find_by(youtube_id: 'bbbbbbbbbbb').id}[src]", false
  end

  test "the progress frame renders one row without the layout" do
    sv = @project.source_videos.create!(youtube_id: "aaaaaaaaaaa", url: "https://y/a", status: "downloading")
    sv.pipeline_jobs.create!(status: "started", stage: "Audio download", progress: 15)

    get project_source_path(@project, sv)

    assert_response :success
    assert_select "turbo-frame#source_video_#{sv.id}"
    assert_select "aside", false # no sidebar → no layout
  end

  test "a source video from another project is not found here (leakage guard)" do
    other = Project.create!(name: "Other")
    theirs = other.source_videos.create!(youtube_id: "ccccccccccc", url: "https://y/c")

    get project_source_path(@project, theirs)
    assert_response :not_found
  end
end
