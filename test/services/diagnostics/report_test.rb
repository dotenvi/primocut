require "test_helper"

# The doctor logic, exercised entirely through injected fakes — no GPU, no
# network, no real binaries. Ported from the PoC `tests/test_doctor.py`.
class Diagnostics::ReportTest < ActiveSupport::TestCase
  RunResult = Diagnostics::RunResult

  # A shell fake: each command (matched by a substring of its joined form) maps to
  # a canned RunResult. Anything unmatched is a healthy no-op.
  class FakeRun
    def initialize(rules) = @rules = rules

    def call(cmd, timeout: nil)
      joined = cmd.join(" ")
      _, res = @rules.find { |pattern, _| joined.include?(pattern) }
      res || RunResult.new(out: "ok", err: "", ok: true, missing: false)
    end
  end

  class FakeEngine
    def initialize(envelope: nil, error: nil) = (@envelope, @error = envelope, error)
    def doctor
      raise Adapters::TranscriptionEngine::TranscriptionError, @error if @error

      @envelope
    end
  end

  class FakeYoutube
    def initialize(units: 1, error: nil) = (@units, @error = units, error)
    def probe
      raise @error if @error

      @units
    end
  end

  def ok_run(out = "ok") = RunResult.new(out:, err: "", ok: true, missing: false)
  def failed_run(err = "boom") = RunResult.new(out: "", err:, ok: false, missing: false)
  def missing_run = RunResult.new(out: "", err: "", ok: false, missing: true)

  def healthy_report(overrides = {})
    Diagnostics::Report.new(
      run: overrides[:run] || FakeRun.new([
        [ "nvidia-smi", ok_run("NVIDIA GeForce RTX 3070 Ti, 8192 MiB") ],
        [ "-version", ok_run("ffmpeg version 6.1") ],
        [ "h264_nvenc", ok_run ],
        [ "yt-dlp --version", ok_run("2024.08.06") ]
      ]),
      engine: overrides[:engine] || -> { FakeEngine.new(envelope: { "ok" => true, "python" => "3.13.5", "faster_whisper" => "1.2.1", "cuda_device_count" => 1 }) },
      youtube: overrides[:youtube] || -> { FakeYoutube.new(units: 1) },
      env: overrides.fetch(:env, { "ANTHROPIC_API_KEY" => "sk-ant-xxx" }),
      db: overrides[:db] || -> { "primocut_test" }
    )
  end

  def check(report, name_fragment)
    report.call.find { |c| c.name.include?(name_fragment) }
  end

  test "a fully healthy environment passes every hard check" do
    checks = healthy_report.call
    assert checks.none?(&:failed?), "unexpected failures: #{checks.select(&:failed?).map(&:name)}"
    assert_equal 8, checks.size
  end

  test "GPU check fails when nvidia-smi is absent, with a fix" do
    report = healthy_report(run: FakeRun.new([ [ "nvidia-smi", missing_run ] ]))
    c = check(report, "GPU")
    assert c.failed?
    assert_match(/nvidia-smi not found/, c.detail)
    assert c.fix.present?
  end

  test "FFmpeg check fails when the binary is missing" do
    report = healthy_report(run: FakeRun.new([ [ "-version", missing_run ] ]))
    assert check(report, "FFmpeg").failed?
  end

  test "NVENC is a soft warning, never a hard failure, when it cannot encode" do
    report = healthy_report(run: FakeRun.new([
      [ "nvidia-smi", ok_run ], [ "-version", ok_run ],
      [ "h264_nvenc", failed_run("Cannot load nvcuda") ], [ "yt-dlp", ok_run("x") ]
    ]))
    c = check(report, "NVENC")
    assert c.warn
    refute c.failed?
    assert_match(/libx264/, c.fix)
  end

  test "yt-dlp check fails when the binary is missing" do
    report = healthy_report(run: FakeRun.new([ [ "yt-dlp --version", missing_run ] ]))
    assert check(report, "yt-dlp").failed?
  end

  test "sidecar check reports the engine health envelope" do
    c = check(healthy_report, "sidecar")
    assert c.passed?
    assert_match(/faster-whisper 1.2.1/, c.detail)
  end

  test "sidecar check fails when the engine reports not ok" do
    report = healthy_report(engine: -> { FakeEngine.new(envelope: { "ok" => false, "cuda_error" => "no CUDA device" }) })
    c = check(report, "sidecar")
    assert c.failed?
    assert_match(/no CUDA device/, c.detail)
  end

  test "sidecar check fails when the engine cannot be driven" do
    report = healthy_report(engine: -> { FakeEngine.new(error: "sidecar failed: venv missing") })
    assert check(report, "sidecar").failed?
  end

  test "LLM key check fails when ANTHROPIC_API_KEY is unset" do
    report = healthy_report(env: {})
    c = check(report, "LLM key")
    assert c.failed?
    assert_match(/not set/, c.detail)
  end

  test "YouTube check fails when the key is missing" do
    report = healthy_report(youtube: -> { raise Adapters::YoutubeApi::Error, "YOUTUBE_API_KEY is not set." })
    c = check(report, "YouTube")
    assert c.failed?
    assert_match(/not set/, c.detail)
  end

  test "database check fails when the connection cannot be reached" do
    report = healthy_report(db: -> { raise StandardError, "could not connect to server" })
    c = check(report, "Database")
    assert c.failed?
    assert_match(/could not connect/, c.detail)
  end
end
