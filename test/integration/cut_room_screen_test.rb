require "test_helper"
require "tmpdir"
require "fileutils"

# The Cut Room, per source video: topics + triage, composing the cut, and the
# export bundle. Scoped to the project (leakage guard).
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

  # ------------------------- section 3: export -------------------------

  test "export enqueues the job, seeds the export row, and polls" do
    cut = @video.cuts.create!
    item = cut.cut_items.create!(position: 0, topic: @topic, start_s: 100, end_s: 130)
    item.create_clip!(source_video_id: @video.id, cut_id: cut.id, position: 0, rel_path: "x", state: "done")

    assert_enqueued_with(job: CutExportJob) do
      post project_cut_export_path(@project, @video), params: { skip_master: "1" }
    end
    assert cut.reload.export.state_queued?

    get project_cut_room_path(@project, @video)
    assert_select "turbo-frame#cut_export[src][data-controller=?]", "poll"
  end

  test "the finished export offers the zip for download" do
    Dir.mktmpdir do |dir|
      ENV["EXPORTS_DIR"] = dir
      cut = @video.cuts.create!
      zip_rel = "#{@video.youtube_id}/#{cut.id}/best-20260101.zip"
      full = File.join(dir, zip_rel)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, "ZIPBYTES")
      cut.create_export!(source_video_id: @video.id, state: "done", zip_rel_path: zip_rel, item_count: 2)

      get project_download_cut_export_path(@project, @video)
      assert_response :success
      assert_equal "ZIPBYTES", response.body
    ensure
      ENV.delete("EXPORTS_DIR")
    end
  end

  test "download is not found before the export is ready" do
    @video.cuts.create!
    get project_download_cut_export_path(@project, @video)
    assert_response :not_found
  end

  # ------------------------- section 4: AI packaging -------------------------

  test "each packaging action enqueues its matching job" do
    cut = @video.cuts.create!
    cut.cut_items.create!(position: 0, topic: @topic, start_s: 100, end_s: 130)

    assert_enqueued_with(job: CutPackagingJob) { post project_cut_packaging_path(@project, @video), params: { kind: "title" } }
    assert_enqueued_with(job: ExtractCutFramesJob) { post project_cut_packaging_path(@project, @video), params: { kind: "frames" } }
    assert_enqueued_with(job: RankCutFramesJob) { post project_cut_packaging_path(@project, @video), params: { kind: "rank" } }
    assert_enqueued_with(job: MatchAudienceJob) { post project_cut_packaging_path(@project, @video), params: { kind: "audience" } }
  end

  test "an unknown packaging kind is rejected without enqueuing" do
    @video.cuts.create!
    assert_no_enqueued_jobs do
      post project_cut_packaging_path(@project, @video), params: { kind: "bogus" }
    end
    assert_equal "Unknown packaging action.", flash[:alert]
  end

  test "generated titles appear on the packaging panel" do
    cut = @video.cuts.create!
    item = cut.cut_items.create!(position: 0, topic: @topic, start_s: 100, end_s: 130)
    CutPackaging.create!(cut_item: item, cut_id: cut.id, kind: "title", state: "done",
                         payload: { "titles" => [ { "title" => "A Punchy Title", "length_chars" => 14 } ] })

    get project_cut_room_path(@project, @video)
    assert_select "li", text: /A Punchy Title/
  end

  test "a running packaging pass polls the panel" do
    cut = @video.cuts.create!
    item = cut.cut_items.create!(position: 0, topic: @topic, start_s: 100, end_s: 130)
    CutPackaging.create!(cut_item: item, cut_id: cut.id, kind: "title", state: "running")

    get project_cut_room_path(@project, @video)
    assert_select "turbo-frame#cut_packaging[src][data-controller=?]", "poll"
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
