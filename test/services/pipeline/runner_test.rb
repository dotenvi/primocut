require "test_helper"

# Tests for the pipeline stage core. Every external call is a fake, so the whole
# run exercises the real caching/degradation/orchestration with no network or
# GPU. Ported from the PoC `tests/test_pipeline.py`.
class Pipeline::RunnerTest < ActiveSupport::TestCase
  Metadata = Adapters::Ytdlp::Metadata
  Msg = Data.define(:offset_seconds, :text)

  class FakeYtdlp
    attr_reader :download_calls

    def initialize(meta:, fail_metadata: false, fail_download: false)
      @meta = meta
      @fail_metadata = fail_metadata
      @fail_download = fail_download
      @download_calls = 0
    end

    def fetch_metadata(_url)
      raise "network down" if @fail_metadata

      @meta
    end

    def download_audio(_url, dir, video_id:)
      @download_calls += 1
      raise Adapters::Ytdlp::Error, "extractor broke" if @fail_download

      "#{dir}/#{video_id}.16k.wav"
    end
  end

  class FakeEngine
    attr_reader :calls, :degradation_warnings

    def initialize(transcript:, warnings: [])
      @transcript = transcript
      @degradation_warnings = warnings
      @calls = 0
    end

    def transcribe(_audio_path, video_id:)
      @calls += 1
      @transcript
    end
  end

  class FakeChat
    def initialize(messages)
      @messages = messages
    end

    def download(_url)
      @messages
    end
  end

  class SpyReporter
    attr_reader :updates

    def initialize
      @updates = []
    end

    def update(stage:, progress:, video_status: nil)
      @updates << { stage: stage, progress: progress, video_status: video_status }
    end
  end

  def setup
    @project = Project.create!(name: "Niche")
    @sv = @project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1", title: "submitted")
  end

  def meta(duration_s: 200)
    Metadata.new(youtube_id: "abcdefghijk", url: "https://y/1", title: "Real Title", channel: "Real Channel", duration_s: duration_s)
  end

  def transcript_value(segs: [ [ 0, 0.0, 90.0, "olá" ] ])
    Pipeline::Transcript.new(
      youtube_id: "abcdefghijk", language: "pt", model: "faster-whisper:m",
      segments: segs.map { |i, s, e, t| Pipeline::Segment.new(index: i, start: s, end: e, text: t) }
    )
  end

  def runner(ytdlp:, engine:, chat:)
    Pipeline::Runner.new(ytdlp: ytdlp, engine: engine, chat_downloader: chat)
  end

  test "runs every stage, persists the artifacts and refreshes metadata" do
    ytdlp = FakeYtdlp.new(meta: meta)
    engine = FakeEngine.new(transcript: transcript_value)
    chat = FakeChat.new([ Msg.new(offset_seconds: 5, text: "kkkk"), Msg.new(offset_seconds: 65, text: "hi") ])
    reporter = SpyReporter.new

    result = Dir.mktmpdir do |dir|
      runner(ytdlp: ytdlp, engine: engine, chat: chat).call(@sv, reporter: reporter, audio_dir: dir)
    end

    @sv.reload
    assert_equal "Real Title", @sv.title
    assert_equal "Real Channel", @sv.channel
    assert_equal 200, @sv.duration_s
    assert_equal :done, reporter.updates.last[:video_status], "the reporter drives the status transition"
    assert_equal 1, @sv.transcript.segments.size
    assert_equal "olá", @sv.transcript.segments.first["text"]
    assert_equal 2, @sv.chat_signal.per_minute.size
    assert_empty result.warnings
    assert_equal [ "Metadata", "Audio download", "Transcription", "Chat", "Done" ], reporter.updates.map { |u| u[:stage] }
  end

  test "a cached transcript skips the download and the GPU" do
    @sv.create_transcript!(language: "pt", model: "m", segments: [ { "index" => 0, "start" => 0.0, "end" => 12.0, "text" => "cached" } ])
    engine = FakeEngine.new(transcript: transcript_value)
    ytdlp = FakeYtdlp.new(meta: meta)

    Dir.mktmpdir do |dir|
      runner(ytdlp: ytdlp, engine: engine, chat: FakeChat.new(nil)).call(@sv, reporter: SpyReporter.new, audio_dir: dir)
    end

    assert_equal 0, ytdlp.download_calls, "no download on a cache hit"
    assert_equal 0, engine.calls, "no transcription on a cache hit"
  end

  test "metadata failure degrades to a warning and keeps the submitted data" do
    ytdlp = FakeYtdlp.new(meta: meta, fail_metadata: true)
    engine = FakeEngine.new(transcript: transcript_value)
    reporter = SpyReporter.new

    result = Dir.mktmpdir do |dir|
      runner(ytdlp: ytdlp, engine: engine, chat: FakeChat.new(nil)).call(@sv, reporter: reporter, audio_dir: dir)
    end

    assert_equal "submitted", @sv.reload.title, "keeps the submitted title"
    assert_equal :done, reporter.updates.last[:video_status]
    assert_equal 1, result.warnings.size
    assert_match "Metadata unavailable", result.warnings.first
  end

  test "degraded duration is filled from the transcript" do
    ytdlp = FakeYtdlp.new(meta: meta(duration_s: 0))
    engine = FakeEngine.new(transcript: transcript_value(segs: [ [ 0, 0.0, 90.0, "x" ] ]))

    Dir.mktmpdir do |dir|
      runner(ytdlp: ytdlp, engine: engine, chat: FakeChat.new(nil)).call(@sv, reporter: SpyReporter.new, audio_dir: dir)
    end

    assert_equal 90, @sv.reload.duration_s
  end

  test "an essential-stage failure raises Pipeline::Error and persists no transcript" do
    ytdlp = FakeYtdlp.new(meta: meta, fail_download: true)
    engine = FakeEngine.new(transcript: transcript_value)

    Dir.mktmpdir do |dir|
      assert_raises(Pipeline::Error) do
        runner(ytdlp: ytdlp, engine: engine, chat: FakeChat.new(nil)).call(@sv, reporter: SpyReporter.new, audio_dir: dir)
      end
    end

    assert_nil @sv.reload.transcript
  end

  test "no usable chat replay is not a failure" do
    ytdlp = FakeYtdlp.new(meta: meta)
    engine = FakeEngine.new(transcript: transcript_value)
    reporter = SpyReporter.new

    result = Dir.mktmpdir do |dir|
      runner(ytdlp: ytdlp, engine: engine, chat: FakeChat.new(nil)).call(@sv, reporter: reporter, audio_dir: dir)
    end

    assert_nil @sv.reload.chat_signal
    assert_nil result.chat_signal
    assert_equal :done, reporter.updates.last[:video_status]
  end

  test "engine degradation warnings surface in the result" do
    ytdlp = FakeYtdlp.new(meta: meta)
    engine = FakeEngine.new(transcript: transcript_value, warnings: [ "degraded to int8" ])

    result = Dir.mktmpdir do |dir|
      runner(ytdlp: ytdlp, engine: engine, chat: FakeChat.new(nil)).call(@sv, reporter: SpyReporter.new, audio_dir: dir)
    end

    assert_equal [ "degraded to int8" ], result.warnings
  end
end
