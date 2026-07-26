require "test_helper"

# The Sources screen: submit a YouTube link, list what the project has processed
# with the topics each one yielded, follow a run live, and re-run a settled one.
class SourcesScreenTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @project = Project.create!(name: "Chess")
    @path = project_sources_path(@project)
  end

  def source(id: "abcdefghijk", title: "A Talk", status: "done", channel: "A Channel")
    @project.source_videos.create!(youtube_id: id, url: "https://y/#{id}", title: title,
      channel: channel, status: status)
  end

  test "lists the project's videos" do
    source

    get @path
    assert_response :success
    assert_select "td", text: "A Talk"
    assert_select "td", text: "A Channel"
  end

  test "the submit field is closed until asked for" do
    source

    get @path
    assert_select "form[action=?]", @path, count: 0
    assert_select "a", text: "+ New video"

    get project_sources_path(@project, new: 1)
    assert_select "form[action=?]", @path
    assert_select "a[href=?]", @path, text: "+ New video" # and the same control closes it
  end

  test "the field sits in a card at the table's own measure" do
    get project_sources_path(@project, new: 1)

    # Same 1160px the table holds, so the field and the list line up.
    assert_select "form.card.max-w-\\[1160px\\]"
    assert_select "form.card p", text: /Lands in Chess/
    assert_select "form.card p", text: /you don't pick it twice/
  end

  test "an empty niche offers the field from its own empty state" do
    get @path
    assert_select "a[href=?]", project_sources_path(@project, new: 1), text: "+ New video"
  end

  test "opening the field keeps an open pipeline open" do
    video = source

    get project_sources_path(@project, pipeline: video.id)
    assert_select "a[href=?]", project_sources_path(@project, pipeline: video.id, new: 1),
      text: "+ New video"
  end

  test "a rejected link leaves the field open, holding the error" do
    post @path, params: { source_video: { url: "https://vimeo.com/123" } }

    assert_redirected_to project_sources_path(@project, new: 1)
    follow_redirect!
    assert_select "form[action=?]", @path
    assert_select ".text-err"
  end

  test "an empty niche says so" do
    get @path
    assert_select "h2", text: /No source video in this niche yet/
  end

  test "the topics a video yielded are counted, and none reads as a dash" do
    with_topics = source
    with_topics.transcript = Transcript.create!(source_video: with_topics, segments: [], language: "pt")
    2.times { |i| with_topics.topics.create!(title: "T#{i}", start_s: i, end_s: i + 5, score: 0.5) }
    source(id: "bbbbbbbbbbb", title: "No topics")

    get @path
    assert_select "td.font-mono", text: "2"
    assert_select "td.font-mono.text-ink-3", text: "—"
  end

  test "a video with a transcript links through to the cut room" do
    video = source
    Transcript.create!(source_video: video, segments: [], language: "pt")

    get @path
    assert_select "a[href=?]", project_cut_room_path(@project, video), text: "A Talk"
  end

  test "a video with no transcript is named but not linked" do
    source

    get @path
    assert_select "a[href=?]", project_cut_room_path(@project, SourceVideo.last), count: 0
    assert_select "td span", text: "A Talk"
  end

  test "the list polls only while something is in flight" do
    active = source(id: "aaaaaaaaaaa", status: "transcribing")
    active.pipeline_jobs.create!(status: "started", stage: "Transcription", progress: 30)

    get @path
    assert_select "turbo-frame#source_videos[src=?]", project_sources_list_path(@project)
    assert_select "turbo-frame#source_videos[data-controller=?]", "poll"
    assert_select ".m", text: /Transcription · 30%/
  end

  test "a settled list does not poll" do
    source(status: "done")

    get @path
    assert_select "turbo-frame#source_videos:not([src])"
    assert_select "turbo-frame#source_videos[data-controller=?]", "poll", count: 0
  end

  test "the polling frame renders the list alone, without the page around it" do
    active = source(id: "aaaaaaaaaaa", status: "downloading")
    active.pipeline_jobs.create!(status: "started", stage: "Audio download", progress: 15)

    get project_sources_list_path(@project)
    assert_response :success
    assert_select "turbo-frame#source_videos"
    assert_select "aside", count: 0 # no sidebar → no layout
  end

  test "a failed run shows why it failed" do
    failed = source(id: "aaaaaaaaaaa", status: "error")
    failed.pipeline_jobs.create!(status: "failed", stage: "Transcription", error: "ffmpeg exited 1")

    get @path
    assert_select ".text-err", text: /ffmpeg exited 1/
  end

  test "submitting a valid link queues the pipeline" do
    assert_enqueued_with(job: SourceVideoPipelineJob) do
      post @path, params: { source_video: { url: "https://youtu.be/abcdefghijk" } }
    end

    assert_redirected_to @path
    video = @project.source_videos.find_by(youtube_id: "abcdefghijk")
    assert_equal "https://www.youtube.com/watch?v=abcdefghijk", video.url
    assert video.queued?
  end

  test "an invalid link is rejected without creating anything" do
    assert_no_enqueued_jobs do
      assert_no_difference -> { SourceVideo.count } do
        post @path, params: { source_video: { url: "https://vimeo.com/123" } }
      end
    end

    follow_redirect!
    assert_select ".text-err"
  end

  test "re-submitting a link the project already holds re-runs it" do
    existing = source(id: "abcdefghijk", status: "error")

    assert_no_difference -> { @project.source_videos.count } do
      post @path, params: { source_video: { url: "https://youtu.be/abcdefghijk" } }
    end

    assert existing.reload.queued?
  end

  test "the panel is absorbed by the canvas, not by the table" do
    video = source

    # Closed, the list keeps the comfortable reading measure...
    get @path
    assert_select "main.max-w-\\[1680px\\]"
    assert_select "div.max-w-\\[1160px\\] > table"

    # ...open, the container grows by exactly the panel plus the gap, so the
    # table keeps the very same measure instead of drifting.
    get project_sources_path(@project, pipeline: video.id)
    assert_select "div.max-w-\\[1620px\\] > table"   # 1160 + 20 gap + 440 panel
    assert_select "#pipeline_panel.w-\\[440px\\]"
  end

  test "reading screens keep the comfortable measure" do
    get project_settings_path(@project)
    assert_select "main.max-w-\\[1160px\\]"
  end

  test "every row offers to open its pipeline" do
    video = source

    get @path
    assert_select "a[href=?]", project_sources_path(@project, pipeline: video.id)
    assert_select "#pipeline_panel", count: 0 # closed by default
  end

  test "opening a pipeline shows its per-step log beside the table" do
    video = source
    video.pipeline_jobs.create!(status: "finished", stage: "Done", progress: 100,
      stage_history: [ { "stage" => "Metadata", "at" => "2026-02-01T00:00:00Z" },
                       { "stage" => "Done", "at" => "2026-02-01T00:00:08Z" } ])
    Transcript.create!(source_video: video, segments: [ { "start" => 0, "end" => 1 } ], language: "pt")

    get project_sources_path(@project, pipeline: video.id)
    assert_response :success
    assert_select "#pipeline_panel .lbl", text: "Pipeline"
    assert_select "#pipeline_panel .m", text: "Metadata"
    assert_select "#pipeline_panel .m", text: "Transcription"
    assert_select "#pipeline_panel", text: /8s/          # the duration the timestamps give
    assert_select "#pipeline_panel .text-ok", text: "complete"
  end

  test "the open pipeline closes from the same control" do
    video = source

    get project_sources_path(@project, pipeline: video.id)
    assert_select "a.text-accent[href=?]", project_sources_path(@project)
  end

  test "the open pipeline survives a poll" do
    video = source(id: "aaaaaaaaaaa", status: "transcribing")

    get project_sources_path(@project, pipeline: video.id)
    assert_select "turbo-frame#source_videos[src=?]",
      project_sources_list_path(@project, pipeline: video.id.to_s)
  end

  test "a finished video can be run again — that is what re-running is for" do
    done = source(status: "done")

    get project_sources_path(@project, pipeline: done.id)
    assert_select "#pipeline_panel button", text: "Rerun stages"

    assert_enqueued_with(job: SourceVideoPipelineJob) { post project_rerun_source_path(@project, done) }
    assert done.reload.queued?
  end

  test "a failed video can be re-run from its pipeline" do
    failed = source(id: "aaaaaaaaaaa", status: "error")

    get project_sources_path(@project, pipeline: failed.id)
    assert_select "#pipeline_panel form[action=?]", project_rerun_source_path(@project, failed)

    assert_enqueued_with(job: SourceVideoPipelineJob) do
      post project_rerun_source_path(@project, failed)
    end
    assert failed.reload.queued?
  end

  test "an in-flight video offers no re-run, and refuses one" do
    active = source(id: "aaaaaaaaaaa", status: "transcribing")

    get project_sources_path(@project, pipeline: active.id)
    assert_select "form[action=?]", project_rerun_source_path(@project, active), count: 0

    assert_no_enqueued_jobs only: SourceVideoPipelineJob do
      post project_rerun_source_path(@project, active)
    end
    follow_redirect!
    assert_select ".text-err", text: /already being processed/
  end

  test "another project's video cannot be re-run through this one" do
    other = Project.create!(name: "Other")
    theirs = other.source_videos.create!(youtube_id: "ccccccccccc", url: "https://y/c", status: "error")

    post project_rerun_source_path(@project, theirs)
    assert_response :not_found
  end
end
