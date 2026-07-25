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

  # ------------------------- section 2: composing the cut -------------------------

  test "adding a topic appends a cut item snapshotting its range" do
    assert_difference -> { CutItem.count }, 1 do
      post project_cut_items_path(@project, @video), params: { topic_id: @topic.id }
    end
    item = @video.cuts.first.cut_items.first
    assert_equal @topic.id, item.topic_id
    assert_equal 100.0, item.start_s
    assert_equal 130.0, item.end_s

    # The topic now reads as added on the page.
    get project_cut_room_path(@project, @video)
    assert_select "span", text: "Added"
  end

  test "a manual range is added; an invalid range is rejected" do
    assert_difference -> { CutItem.count }, 1 do
      post project_cut_items_path(@project, @video), params: { start_s: "10", end_s: "25" }
    end

    assert_no_difference -> { CutItem.count } do
      post project_cut_items_path(@project, @video), params: { start_s: "30", end_s: "20" }
    end
    assert_equal "Enter a valid start and end (end after start).", flash[:alert]
  end

  test "removing an item re-packs the remaining positions" do
    cut = @video.cuts.create!
    a = cut.cut_items.create!(position: 0, start_s: 0, end_s: 5)
    b = cut.cut_items.create!(position: 1, start_s: 5, end_s: 10)

    delete project_cut_item_path(@project, @video, a)
    assert_equal 0, b.reload.position
  end

  test "moving an item swaps it with its neighbour" do
    cut = @video.cuts.create!
    a = cut.cut_items.create!(position: 0, start_s: 0, end_s: 5)
    b = cut.cut_items.create!(position: 1, start_s: 5, end_s: 10)

    post project_move_cut_item_path(@project, @video, a), params: { direction: "down" }
    assert_equal 1, a.reload.position
    assert_equal 0, b.reload.position
  end

  test "render enqueues the render job, flips the cut to rendering, and polls" do
    cut = @video.cuts.create!
    cut.cut_items.create!(position: 0, topic: @topic, start_s: 100, end_s: 130)

    assert_enqueued_with(job: CutRenderJob) do
      post project_render_cut_path(@project, @video)
    end
    assert cut.reload.status_rendering?

    get project_cut_room_path(@project, @video)
    assert_select "turbo-frame#cut_composition[src][data-controller=?]", "poll"
  end

  test "the cut frame renders on its own without the layout" do
    get project_cut_path(@project, @video)
    assert_response :success
    assert_select "turbo-frame#cut_composition"
    assert_select "aside", false
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
