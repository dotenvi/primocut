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

  test "a topic row carries one control: put it in the cut" do
    get project_cut_room_path(@project, @video)

    assert_response :success
    assert_select "h1", /A Live/
    assert_select ".card", text: /Opening Bell/
    assert_select "form[action=?]", project_cut_items_path(@project, @video)
    # Deciding is done by watching and composing, not by filing an opinion first.
    assert_select "form[action=?]", project_topic_triage_path(@project, @video, @topic), count: 0
  end

  test "a topic's summary is folded away, and its title is what unfolds it" do
    get project_cut_room_path(@project, @video)

    assert_select "[data-disclosure-target=detail][hidden]", text: "the intro"
    assert_select "button[data-disclosure-target=trigger][data-action=?]", "disclosure#toggle",
      text: /Opening Bell/
    # Trigger and detail are paired by key, and the controller that pairs them sits
    # outside the frame composing replaces — otherwise every Add refolds the bench.
    assert_select "button[data-disclosure-target=trigger][data-key=?]", @topic.id.to_s
    assert_select "[data-disclosure-target=detail][data-key=?]", @topic.id.to_s
    assert_select "[data-controller=disclosure] turbo-frame#cut_topics"
  end

  test "a topic's start plays the source from there" do
    get project_cut_room_path(@project, @video)

    assert_select "button[data-controller=seek][data-seek-seconds-value=?]", "100.0", text: "1:40–2:10"
    # The seek is announced to the room, so the stage has to come back to the source
    # player — on the rendered cut it would move a video nobody can see.
    assert_select "[data-controller=cut-preview][data-action=?]",
      "player:seek@window->cut-preview#source"
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

    # The same control now offers to take it back out.
    get project_cut_room_path(@project, @video)
    assert_select "#cut_topics form[action=?][method=post]", project_cut_item_path(@project, @video, item)
    assert_select "#cut_topics input[name=_method][value=delete]"
    assert_select "#cut_topics button", text: "✓ In cut"
  end

  test "taking a topic back out from the bench asks only when there is a clip to lose" do
    post project_cut_items_path(@project, @video), params: { topic_id: @topic.id }
    item = @video.cuts.first.cut_items.first

    row = "#cut_topics form[action='#{project_cut_item_path(@project, @video, item)}']"

    get project_cut_room_path(@project, @video)
    assert_select "#{row}[data-turbo-confirm]", count: 0

    item.create_clip!(cut_id: item.cut_id, source_video_id: @video.id, state: "done", rel_path: "001-opening.mp4")
    get project_cut_room_path(@project, @video)
    assert_select "#{row}[data-turbo-confirm=?]", "Remove this item and its clip?"
  end

  test "a manual range is added; an invalid range is rejected" do
    assert_difference -> { CutItem.count }, 1 do
      post project_cut_items_path(@project, @video), params: { start_s: "10", end_s: "25" }
    end

    assert_no_difference -> { CutItem.count } do
      post project_cut_items_path(@project, @video), params: { start_s: "30", end_s: "20" }
    end
    assert_match(/Enter a valid start and end/, flash[:alert])
  end

  test "a range is typed the way the room shows it" do
    # The timestamps on screen are clock time, so the field takes clock time —
    # nobody should have to convert 1:05 to 65 by hand.
    assert_difference -> { CutItem.count }, 1 do
      post project_cut_items_path(@project, @video), params: { start_s: "1:05", end_s: "1:35" }
    end

    item = CutItem.order(:id).last
    assert_equal 65.0, item.start_s
    assert_equal 95.0, item.end_s
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
    assert_select "[data-controller=?][data-stream-poll-url-value=?]",
      "stream-poll", project_cut_progress_path(@project, @video)
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

    # The export rides the composition's poller — it has no frame of its own.
    get project_cut_room_path(@project, @video)
    assert_select "[data-controller=?][data-stream-poll-url-value=?]",
      "stream-poll", project_cut_progress_path(@project, @video)
  end

  # ---- the export lives inside the composition ----

  test "the export's button sits with Render, and its options with the composing controls" do
    with_clips do
      get project_cut_room_path(@project, @video)

      # One card, so both are inside the composition frame.
      assert_select "turbo-frame#cut_composition" do
        assert_select "form[action=?]", project_render_cut_path(@project, @video)
        assert_select "form[action=?][id=?]", project_cut_export_path(@project, @video), "cut_export_form"
        # The button is in the header, its options at the bottom: `form=` is what
        # joins them, since a <form> around both would nest inside Render's own.
        assert_select "button[type=submit][form=?]", "cut_export_form"
        assert_select "#cut_export_form input[name=?]", "skip_master"
        assert_select "#cut_export_form input[name=?]", "upscale"
      end
    end
  end

  test "the export options form carries no submit of its own" do
    with_clips do
      get project_cut_room_path(@project, @video)
      assert_select "#cut_export_form input[type=submit]", count: 0
      assert_select "#cut_export_form button[type=submit]", count: 0
    end
  end

  test "exporting is refused until something is rendered, and says why" do
    add_item
    get project_cut_room_path(@project, @video)

    assert_select "button[form=cut_export_form][disabled]" do |els|
      assert_match(/Render at least one clip first/, els.first["title"])
    end
  end

  test "a finished export offers its zip from inside the composition" do
    Dir.mktmpdir do |dir|
      ENV["EXPORTS_DIR"] = dir
      cut = @video.active_cut
      cut.cut_items.create!(position: 0, start_s: 0, end_s: 5)
      cut.create_export!(source_video_id: @video.id, state: "done", zip_rel_path: "a.zip", item_count: 3)

      get project_cut_room_path(@project, @video)
      assert_select "turbo-frame#cut_composition" do
        assert_select "a[href=?]", project_download_cut_export_path(@project, @video)
        assert_select "span", text: /3 clips/
      end
    ensure
      ENV.delete("EXPORTS_DIR")
    end
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
  test "the room is three columns: stage, bench and composition" do
    get project_cut_room_path(@project, @video)
    assert_response :success

    # The bench drives the page scroll; the side columns stick to the top.
    assert_select "div.min-\\[1201px\\]\\:grid-cols-\\[minmax\\(0\\,1fr\\)_440px_360px\\]"
    assert_select "div.min-\\[1201px\\]\\:sticky", count: 3
    # The canvas is generous here — the room is not a reading screen.
    assert_select "main.max-w-\\[1680px\\]"
  end

  test "the stage carries the player" do
    get project_cut_room_path(@project, @video)

    assert_select "[data-controller=?][data-player-video-id-value=?]", "player", @video.youtube_id
    assert_select ".player-frame [data-player-mount]"
  end

  test "every transcript line seeks the player" do
    @video.transcript&.destroy
    Transcript.create!(source_video: @video, language: "pt",
      segments: [ { "index" => 0, "start" => 61.5, "end" => 64.0, "text" => "primeira linha" } ])

    get project_cut_room_path(@project, @video)
    assert_select "[data-controller=?][data-seek-seconds-value=?]", "seek", "61.5"
    assert_select "button", text: "1:01"
    assert_select "span", text: "primeira linha"
  end

  test "the transcript carries its search, wired to every line" do
    @video.transcript&.destroy
    Transcript.create!(source_video: @video, language: "pt", segments: [
      { "index" => 0, "start" => 1.0, "end" => 2.0, "text" => "primeira linha" },
      { "index" => 1, "start" => 3.0, "end" => 4.0, "text" => "segunda linha" }
    ])

    get project_cut_room_path(@project, @video)

    # Filtering happens in place: the lines are already here, so a keystroke must
    # never cost a request.
    assert_select "[data-controller=?]", "transcript-search"
    assert_select "input[data-action=?]", "input->transcript-search#filter"
    assert_select "[data-transcript-search-target=?]", "segment", count: 2
    assert_select "[data-transcript-search-target=?][hidden]", "empty"
  end

  test "a transcript nobody has yet offers no search box" do
    @video.transcript&.destroy

    get project_cut_room_path(@project, @video)
    assert_select "input[data-transcript-search-target=?]", "query", count: 0
  end

  test "a video still processing says so instead of showing an empty transcript" do
    @video.transcript&.destroy
    @video.update!(status: "transcribing")

    get project_cut_room_path(@project, @video)
    assert_select "p.m", text: /Processing — the transcript appears/
  end
  test "adding a topic updates BOTH columns, not just the one clicked from" do
    post project_cut_items_path(@project, @video), params: { topic_id: @topic.id }
    follow_redirect!

    # The button lives in the topics frame but what it changes is the composition.
    # A frame-scoped swap would leave the composition showing yesterday's list.
    assert_select "#cut_composition", text: /Opening Bell/
    assert_select "#cut_topics button", text: "✓ In cut"
    assert_select "#cut_topics form[action=?]", project_cut_items_path(@project, @video), count: 0
  end

  test "removing an item gives the topic back to the bench" do
    cut = @video.active_cut
    item = Cuts::AddItem.new.call(cut: cut, topic_id: @topic.id)

    delete project_cut_item_path(@project, @video, item)
    follow_redirect!

    assert_select "#cut_topics button", text: "✓ In cut", count: 0
    assert_select "#cut_topics form[action=?]", project_cut_items_path(@project, @video)
  end

  test "every panel of the room navigates the page, not itself" do
    get project_cut_room_path(@project, @video)

    # Each action in this room redirects with a flash and usually touches more
    # than one panel, so no frame may swallow the navigation.
    %w[cut_topics cut_composition cut_packaging].each do |frame|
      assert_select "turbo-frame##{frame}[target=?]", "_top"
    end
  end
  test "composing replies with the two panels it changed, not the whole room" do
    post project_cut_items_path(@project, @video), params: { topic_id: @topic.id },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type

    # Both panels the change touches...
    assert_match(/turbo-stream action="replace" target="cut_topics"/, response.body)
    assert_match(/turbo-stream action="replace" target="cut_composition"/, response.body)
    # ...and nothing else: re-sending the transcript would tear down the player.
    assert_no_match(/transcript-search-target="segment"/, response.body)
    assert_no_match(/data-player-mount/, response.body)
  end

  test "the panels carry the change on both sides" do
    post project_cut_items_path(@project, @video), params: { topic_id: @topic.id },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_match(/Opening Bell/, response.body)
    assert_match(/In cut/, response.body)
  end

  test "a client without turbo still gets the whole room back" do
    post project_cut_items_path(@project, @video), params: { topic_id: @topic.id },
      headers: { "Accept" => "text/html" }

    assert_redirected_to project_cut_room_path(@project, @video)
  end
  # ---- the render finishing must reach the rest of the room, without a reload ----

  def rendering_cut
    cut = @video.active_cut
    cut.update!(status: "rendering")
    item = cut.cut_items.create!(position: 0, start_s: 0, end_s: 10)
    item.create_clip!(cut_id: cut.id, source_video_id: @video.id, state: "cutting")
    cut
  end

  # The bug this whole mechanism exists for: the clips landed on disk and the mode
  # switcher went on saying "render the cut to preview it", because a frame reload
  # cannot touch anything outside its own frame.
  test "the progress poll answers with the composition AND the stage, in one response" do
    rendering_cut
    get project_cut_progress_path(@project, @video), as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    %w[cut_composition stage_modes stage_playback].each do |target|
      assert_select "turbo-stream[action=replace][target=?]", target
    end
  end

  # Resending these would cost more than everything it fixes: the iframe restarts
  # playback, the transcript is thousands of segments.
  test "the poll never resends the player or the transcript" do
    rendering_cut
    get project_cut_progress_path(@project, @video), as: :turbo_stream

    assert_no_match(/data-player-mount/, response.body)
    assert_no_match(/transcript-search-target="segment"/, response.body)
  end

  test "playback arrives enabled once the master is on disk, with its segments wired" do
    with_clips(spans: [ 40, 100 ]) do
      get project_cut_progress_path(@project, @video), as: :turbo_stream

      assert_select "turbo-stream[target=stage_modes]" do
        assert_select "[data-cut-preview-mode-param=cut][disabled]", count: 0
      end
      assert_select "turbo-stream[target=stage_playback] [data-cut-preview-target=segment]", count: 2
      assert_select "turbo-stream[target=stage_playback] video[src=?]",
        project_cut_master_path(@project, @video)
    end
  end

  test "the poller stops itself when the render settles" do
    with_clips do
      get project_cut_progress_path(@project, @video), as: :turbo_stream
      assert_select "[data-controller=stream-poll]", count: 0
    end
  end

  test "a poll for another project's cut is not found (leakage guard)" do
    other = Project.create!(name: "Theirs")
    get project_cut_progress_path(other, @video), as: :turbo_stream
    assert_response :not_found
  end

  # ---- what the render is doing, while it does it ----

  test "a render in flight reports how far, how fast and how much longer" do
    cut = @video.active_cut
    cut.update!(status: "rendering")
    a = cut.cut_items.create!(position: 0, start_s: 0, end_s: 100)
    a.create_clip!(cut_id: cut.id, source_video_id: @video.id, state: "done", rel_path: "a.mp4",
                   size_bytes: 70_000_000, created_at: 100.seconds.ago, updated_at: Time.current)
    b = cut.cut_items.create!(position: 1, start_s: 200, end_s: 400)
    b.create_clip!(cut_id: cut.id, source_video_id: @video.id, state: "cutting",
                   created_at: 60.seconds.ago, updated_at: Time.current)

    get project_cut_room_path(@project, @video)

    assert_select "[data-controller=?]", "stream-poll" # still polling
    assert_match(/1 of 2 rendered/, response.body)
    assert_match(/1\.00× per second of video/, response.body) # measured, not guessed
    assert_match(/66\.8 MB/, response.body)
    assert_match(/left/, response.body)                       # the estimate is offered
    assert_select "[title=?]", "5.6 Mb/s"                     # bitrate explains the size
  end

  test "the item in flight is named, with the stage it is in" do
    cut = @video.active_cut
    item = cut.cut_items.create!(position: 0, start_s: 0, end_s: 100)
    item.create_clip!(cut_id: cut.id, source_video_id: @video.id, state: "downloading_section",
                      created_at: 30.seconds.ago, updated_at: Time.current)

    get project_cut_room_path(@project, @video)
    assert_match(/item 1/, response.body)
    assert_match(/Downloading/, response.body)
    assert_match(/30s elapsed/, response.body)
  end

  # "Error" with no reason sends you to the logs; the reason belongs on the screen.
  test "a failed clip shows why it failed" do
    cut = @video.active_cut
    item = cut.cut_items.create!(position: 0, start_s: 0, end_s: 100)
    item.create_clip!(cut_id: cut.id, source_video_id: @video.id, state: "error",
                      error: "yt-dlp exited 1: Sign in to confirm you're not a bot")

    get project_cut_room_path(@project, @video)
    assert_match(/1 failed/, response.body)
    assert_match(/Sign in to confirm/, response.body)
  end

  test "a cut with nothing rendered shows no telemetry to read" do
    add_item
    get project_cut_room_path(@project, @video)

    assert_no_match(/of 1 rendered/, response.body)
    assert_no_match(/per second of video/, response.body)
  end

  # ---- the cut plays as ONE file: the concatenated master ----

  # The regression guard for the whole design: playback must not simulate the cut.
  # Seeking the source lands on keyframes rather than cut points; chaining the clip
  # files pays a file load at every item boundary. Neither is what you export.
  test "the cut plays one file, not the source and not a chain of clips" do
    with_master do
      get project_cut_room_path(@project, @video)

      assert_select "[data-mode=cut] video[src=?]", project_cut_master_path(@project, @video)
      assert_select "[data-mode=cut] [data-start-s]", count: 0   # no source seeking
      assert_select "[data-mode=cut] [data-src]", count: 0       # no clip chaining
    end
  end

  test "the stage offers two modes, source and cut" do
    get project_cut_room_path(@project, @video)
    assert_select "[data-cut-preview-target=mode]", count: 2
    assert_select "[data-cut-preview-mode-param=source]"
    assert_select "[data-cut-preview-mode-param=cut]"
  end

  test "an unplayable cut offers the mode disabled, with the reason" do
    add_item
    get project_cut_room_path(@project, @video)

    assert_select "[data-cut-preview-mode-param=cut][disabled]" do |els|
      assert_match(/0 of 1 clips rendered/, els.first["title"])
    end
  end

  test "the cut mode turns on once the master is on disk" do
    with_master do
      get project_cut_room_path(@project, @video)
      assert_select "[data-cut-preview-mode-param=cut][disabled]", count: 0
    end
  end

  # Each segment seeks INTO the one file, so it needs its offset within the master —
  # the durations of everything before it, not its position in the source.
  test "each segment carries its offset inside the master" do
    with_master(spans: [ 40, 100, 25 ]) do
      get project_cut_room_path(@project, @video)

      assert_select "[data-cut-preview-target=segment]", count: 3
      [ [ 0, 0, 40 ], [ 1, 40, 140 ], [ 2, 140, 165 ] ].each do |i, at, until_s|
        assert_select "[data-cut-preview-index-param=?][data-at=?][data-until=?]",
          i.to_s, at.to_f.to_s, until_s.to_f.to_s
      end
    end
  end

  test "a partly rendered cut has no master, so it cannot be played" do
    with_master do
      # A seventh item nobody rendered: the master no longer covers the composition.
      cut = @video.active_cut
      cut.cut_items.create!(position: 99, start_s: 5, end_s: 9)

      get project_cut_room_path(@project, @video)
      assert_select "[data-cut-preview-mode-param=cut][disabled]"
    end
  end

  test "the master is served with byte ranges so it can be scrubbed" do
    with_master do
      get project_cut_master_path(@project, @video), headers: { "Range" => "bytes=2-5" }

      assert_response :partial_content
      assert_equal "bytes", response.headers["Accept-Ranges"]
      assert_equal "bytes 2-5/11", response.headers["Content-Range"]
      assert_equal "deo ", response.body
    end
  end

  test "an open-ended range is capped rather than pulling the whole file" do
    with_master do
      get project_cut_master_path(@project, @video), headers: { "Range" => "bytes=0-" }

      assert_response :partial_content
      assert_equal "bytes 0-10/11", response.headers["Content-Range"]
    end
  end

  test "a cut with no master serves nothing" do
    get project_cut_master_path(@project, @video)
    assert_response :not_found
  end

  def add_item
    post project_cut_items_path(@project, @video), params: { start_s: "1", end_s: "3" },
      headers: { "Accept" => "text/html" }
  end

  # A concat FFmpeg that writes the bytes instead of shelling out — the real path
  # computation and digest still run, so the master lands where production puts it.
  class FakeConcat
    attr_reader :calls

    def initialize(bytes) = (@bytes, @calls = bytes, [])

    def concat_master(filenames, out, cwd:, upscale: false)
      @calls << { filenames: filenames, cwd: cwd.to_s }
      Pathname(out).dirname.mkpath
      File.write(out, @bytes)
      [ "copy", nil ]
    end
  end

  # A fully rendered cut WITH its master on disk — what playback needs. `spans` are
  # the items' durations, which is what the segment offsets are computed from.
  def with_clips(spans: [ 4 ], master: true, bytes: "video bytes")
    dir = Dir.mktmpdir("primocut-clips-")
    ENV["CLIPS_DIR"] = dir
    cut = @video.active_cut
    spans.each_with_index do |span, i|
      item = cut.cut_items.create!(position: i, start_s: i * 1000, end_s: (i * 1000) + span)
      rel = "#{@video.youtube_id}/#{cut.id}/#{format('%03d-clip.mp4', i + 1)}"
      FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
      File.write(File.join(dir, rel), "clip#{i}")
      item.create_clip!(cut_id: cut.id, source_video_id: @video.id, state: "done", rel_path: rel,
                       position: i, params_hash: "hash#{i}")
    end
    Cuts::Master.new(ffmpeg: FakeConcat.new(bytes), clips_dir: dir).build(cut.reload) if master
    yield
  ensure
    ENV.delete("CLIPS_DIR")
    FileUtils.remove_entry(dir) if dir && File.exist?(dir)
  end

  def with_master(spans: [ 4 ], &block) = with_clips(spans: spans, &block)
end
