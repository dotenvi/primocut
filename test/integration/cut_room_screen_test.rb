require "test_helper"

# The Cut Room, per source video — section 1: topics + triage. Scoped to the
# project (leakage guard). Analyzing enqueues the LLM pass; triage records the
# per-source-video opinion.
class CutRoomScreenTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @project = Project.create!(name: "Chess")
    @video = @project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1", title: "A Live", status: "done")
    @topic = @video.topics.create!(title: "Opening Bell", summary: "the intro", start_s: 100, end_s: 130, score: 0.8)
  end

  test "shows the topics with their triage controls" do
    get project_cut_room_path(@project, @video)

    assert_response :success
    assert_select "h1", /A Live/
    assert_select ".card", text: /Opening Bell/
    assert_select "form[action=?]", project_topic_triage_path(@project, @video, @topic)
  end

  test "analyze enqueues the topic pass, flips to analyzing, and redirects back" do
    assert_enqueued_with(job: AnalyzeTopicsJob) do
      post project_analyze_topics_path(@project, @video)
    end
    assert_redirected_to project_cut_room_path(@project, @video)
    assert @video.reload.analyzing?
  end

  test "an analyzing video polls its topics frame; a settled one does not" do
    @video.update!(status: "analyzing")
    get project_cut_room_path(@project, @video)
    assert_select "turbo-frame#cut_topics[src][data-controller=?]", "poll"

    @video.update!(status: "done")
    get project_cut_room_path(@project, @video)
    assert_select "turbo-frame#cut_topics[src]", false
  end

  test "the topics frame renders on its own without the layout" do
    get project_topics_path(@project, @video)
    assert_response :success
    assert_select "turbo-frame#cut_topics"
    assert_select "aside", false # no sidebar → no layout
  end

  test "triage records maybe, then clears on open" do
    post project_topic_triage_path(@project, @video, @topic), params: { state: "maybe" }
    assert_redirected_to project_cut_room_path(@project, @video)
    assert TopicTriage.find_by(source_video: @video, topic: @topic).state_maybe?

    post project_topic_triage_path(@project, @video, @topic), params: { state: "open" }
    assert_nil TopicTriage.find_by(source_video: @video, topic: @topic)
  end

  test "a source video from another project is not found here (leakage guard)" do
    other = Project.create!(name: "Other")
    theirs = other.source_videos.create!(youtube_id: "ccccccccccc", url: "https://y/c")

    get project_cut_room_path(@project, theirs)
    assert_response :not_found
  end

  test "the sources list links a processed video to its Cut Room" do
    @video.create_transcript!(language: "pt", model: "m", segments: [])
    get project_sources_path(@project)
    assert_select "a[href=?]", project_cut_room_path(@project, @video)
  end
end
