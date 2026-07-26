require "test_helper"

# The single source of stage truth. The distinctions here are the whole point: a
# step is `complete` only with its artifact in hand, and a step that produced
# nothing is told apart by whether the run entered it at all.
class Pipeline::StepsTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Chess")
    @video = @project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1",
      title: "A Talk", status: "done")
  end

  def run!(stage:, status: "finished", history: [], error: nil)
    @video.pipeline_jobs.create!(stage: stage, status: status, error: error.to_s, stage_history: history)
  end

  def trail(*pairs) = pairs.map { |label, at| { "stage" => label, "at" => at } }

  def states = Pipeline::Steps.new(@video).call.to_h { |s| [ s.key, s.state ] }

  test "a step is complete only when its artifact exists" do
    run!(stage: "Done")
    Transcript.create!(source_video: @video, segments: [ { "start" => 0 } ], language: "pt")

    assert_equal "done", states["transcription"]
    assert_equal "done", states["metadata"], "the title is the metadata artifact"
  end

  test "audio counts as complete on the transcript, its deferred evidence" do
    # The audio file is discarded, so it can never evidence itself.
    run!(stage: "Done")
    Transcript.create!(source_video: @video, segments: [ { "start" => 0 } ], language: "pt")

    assert_equal "done", states["audio"]
  end

  test "a stage the run entered but that produced nothing reads as ignored" do
    run!(stage: "Done", history: trail([ "Metadata", "2026-02-01T00:00:00Z" ],
                                       [ "Chat", "2026-02-01T00:00:05Z" ],
                                       [ "Done", "2026-02-01T00:00:06Z" ]))

    assert_equal "empty", states["chat"], "it ran; there was simply no replay"
  end

  test "a stage the run never entered reads as skipped" do
    run!(stage: "Done", history: trail([ "Metadata", "2026-02-01T00:00:00Z" ]))

    assert_equal "skipped", states["topics"], "nobody asked for topics"
  end

  test "the stage in flight is running and the ones after it are queued" do
    @video.update!(status: "transcribing")
    run!(stage: "Transcription", status: "started")

    assert_equal "running", states["transcription"]
    assert_equal "pending", states["chat"]
    assert_equal "pending", states["topics"]
  end

  test "a failure marks the stage it died on" do
    @video.update!(status: "error")
    run!(stage: "Transcription", status: "failed", error: "ffmpeg exited 1")

    assert_equal "failed", states["transcription"]
    assert_equal "failed", Pipeline::Steps.new(@video).overall
  end

  test "durations come from the gaps between transitions" do
    run!(stage: "Done", history: trail([ "Metadata", "2026-02-01T00:00:00Z" ],
                                       [ "Audio download", "2026-02-01T00:00:02Z" ],
                                       [ "Transcription", "2026-02-01T00:00:12Z" ],
                                       [ "Done", "2026-02-01T00:01:12Z" ]))

    by_key = Pipeline::Steps.new(@video).call.to_h { |s| [ s.key, s.duration_s ] }

    assert_equal 2, by_key["metadata"]
    assert_equal 10, by_key["audio"]
    assert_equal 60, by_key["transcription"]
  end

  test "the stage still running measures up to now, so it ticks" do
    @video.update!(status: "transcribing")
    run!(stage: "Transcription", status: "started",
         history: trail([ "Transcription", "2026-02-01T00:00:00Z" ]))

    steps = Pipeline::Steps.new(@video, now: Time.utc(2026, 2, 1, 0, 0, 30)).call

    assert_equal 30, steps.find { |s| s.key == "transcription" }.duration_s
  end

  test "a run imported before timestamps existed still renders, without durations" do
    # The legacy trail is a list of bare stage names.
    run!(stage: "Done", history: [ "Metadata", "Chat", "Done" ])

    steps = Pipeline::Steps.new(@video).call

    assert steps.all? { |s| s.duration_s.nil? }
    assert_equal "empty", states["chat"], "the trail still says the stage was entered"
  end

  test "warnings from the run travel with the log" do
    job = run!(stage: "Done")
    job.update!(warnings: [ "chat replay unavailable" ])

    assert_equal [ "chat replay unavailable" ], Pipeline::Steps.new(@video).warnings
  end
end
