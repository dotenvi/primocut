require "test_helper"
require "json"
require "rbconfig"

# Tests for the transcription sidecar adapter. Unit tests inject a fake runner
# (envelope parsing, out-file reading, error mapping, degradation warnings); one
# integration test drives a fake engine script through the REAL ProcessRunner, so
# the spawn + stdout-envelope + out-file boundary is exercised end to end — with
# no GPU and no faster-whisper.
class Adapters::TranscriptionEngineTest < ActiveSupport::TestCase
  Engine = Adapters::TranscriptionEngine

  class FakeStatus
    def initialize(ok, code = ok ? 0 : 1)
      @ok = ok
      @code = code
    end

    def success? = @ok
    def exitstatus = @code
  end

  # Records the command, optionally runs a side effect (e.g. writing the --out
  # payload), and returns a canned envelope + status — or raises to simulate a
  # timeout.
  class FakeRunner
    attr_reader :cmd

    def initialize(stdout: "", status: FakeStatus.new(true), raise_error: nil, &on_call)
      @stdout = stdout
      @status = status
      @raise_error = raise_error
      @on_call = on_call
    end

    def call(cmd, timeout: nil)
      @cmd = cmd
      raise @raise_error if @raise_error

      @on_call&.call(cmd)
      Adapters::ProcessRunner::Result.new(stdout: @stdout, stderr: "", status: @status)
    end
  end

  def out_path_in(cmd)
    cmd[cmd.index("--out") + 1]
  end

  test "name reflects the model" do
    assert_equal "faster-whisper:large-v3-turbo", Engine.new(engine_cmd: [ "x" ], model: "large-v3-turbo").name
  end

  test "transcribe reads the out-file payload into a Transcript" do
    envelope = { "ok" => true, "segments" => 2, "language" => "pt", "model" => "faster-whisper:m", "degradation_warnings" => [] }
    runner = FakeRunner.new(stdout: envelope.to_json) do |cmd|
      File.write(out_path_in(cmd), {
        "language" => "pt", "model" => "faster-whisper:m",
        "segments" => [
          { "index" => 0, "start" => 0.0, "end" => 1.5, "text" => "olá" },
          { "index" => 1, "start" => 1.5, "end" => 3.0, "text" => "mundo" }
        ]
      }.to_json)
    end

    engine = Engine.new(engine_cmd: [ "engine" ], model: "m", runner: runner)
    transcript = engine.transcribe("/tmp/a.wav", video_id: "abcdefghijk")

    assert_equal "abcdefghijk", transcript.youtube_id
    assert_equal "pt", transcript.language
    assert_equal 2, transcript.segments.size
    assert_equal "mundo", transcript.segments.last.text
    assert_in_delta 3.0, transcript.duration, 0.001
  end

  test "transcribe surfaces the sidecar degradation warnings" do
    warning = "Transcription degraded the compute_type to 'int8'."
    envelope = { "ok" => true, "degradation_warnings" => [ warning ] }
    runner = FakeRunner.new(stdout: envelope.to_json) do |cmd|
      File.write(out_path_in(cmd), { "segments" => [] }.to_json)
    end

    engine = Engine.new(engine_cmd: [ "engine" ], runner: runner)
    engine.transcribe("/tmp/a.wav", video_id: "abcdefghijk")

    assert_equal [ warning ], engine.degradation_warnings
  end

  test "a non-zero exit raises TranscriptionError with the sidecar error body" do
    runner = FakeRunner.new(stdout: { "error" => "RuntimeError: no CUDA" }.to_json, status: FakeStatus.new(false))
    engine = Engine.new(engine_cmd: [ "engine" ], runner: runner)

    error = assert_raises(Engine::TranscriptionError) { engine.transcribe("/tmp/a.wav", video_id: "x") }
    assert_match "no CUDA", error.message
  end

  test "a timeout becomes a TranscriptionError" do
    runner = FakeRunner.new(raise_error: Adapters::ProcessRunner::TimeoutError.new("engine exceeded 1s and was killed"))
    engine = Engine.new(engine_cmd: [ "engine" ], runner: runner)

    error = assert_raises(Engine::TranscriptionError) { engine.transcribe("/tmp/a.wav", video_id: "x") }
    assert_match "killed", error.message
  end

  # End-to-end through the real ProcessRunner against a fake engine implementing
  # the JSON contract (payload to --out, envelope to stdout). No GPU/whisper.
  test "drives a real sidecar process implementing the contract" do
    script = Tempfile.new([ "fake-engine", ".rb" ])
    script.write(<<~RUBY)
      require "json"
      out = ARGV[ARGV.index("--out") + 1]
      File.write(out, { "language" => "pt", "model" => "faster-whisper:fake",
        "segments" => [ { "index" => 0, "start" => 0.0, "end" => 2.0, "text" => "oi" } ] }.to_json)
      print({ "ok" => true, "segments" => 1, "language" => "pt",
        "model" => "faster-whisper:fake", "degradation_warnings" => [] }.to_json)
    RUBY
    script.close

    engine = Engine.new(engine_cmd: [ RbConfig.ruby, script.path ], model: "fake")
    transcript = engine.transcribe("/tmp/a.wav", video_id: "abcdefghijk")

    assert_equal 1, transcript.segments.size
    assert_equal "oi", transcript.segments.first.text
    assert_equal "faster-whisper:fake", transcript.model
  ensure
    script&.unlink
  end
end
