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
      db: overrides[:db] || -> { "primocut_test" },
      readable: overrides[:readable] || ->(_path) { true }
    )
  end

  def check(report, name_fragment)
    report.call.find { |c| c.name.include?(name_fragment) }
  end

  test "a fully healthy environment passes every hard check" do
    checks = healthy_report.call
    assert checks.none?(&:failed?), "unexpected failures: #{checks.select(&:failed?).map(&:name)}"
    assert_equal 9, checks.size
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

  # The regression this whole check exists for: the binary answered `--version`
  # while YouTube refused every extraction, and the doctor reported a green
  # environment right up to the moment a render hung.
  test "the extraction probe fails even when the binary reports a version" do
    report = healthy_report(run: FakeRun.new([
      [ "yt-dlp --version", ok_run("2026.07.04") ],
      [ "-J", failed_run("ERROR: [youtube] BaW_jenozKc: Sign in to confirm you're not a bot. Use --cookies") ]
    ]))
    assert check(report, "yt-dlp").passed?, "the binary row should still pass"
    assert check(report, "extraction").failed?
  end

  test "the bot-check is answered with cookies, not with updating yt-dlp" do
    report = healthy_report(run: FakeRun.new([
      [ "-J", failed_run("ERROR: [youtube] x: Sign in to confirm you're not a bot.") ]
    ]))
    fix = check(report, "extraction").fix
    assert_match(/YTDLP_COOKIES/, fix)
    refute_match(/upgrade yt-dlp/, fix)
  end

  # A broken extractor and a blocked IP need different fixes, so they must not
  # collapse into one generic message.
  test "an extractor failure that is not the bot-check points at yt-dlp itself" do
    report = healthy_report(run: FakeRun.new([
      [ "-J", failed_run("ERROR: unable to extract player version") ]
    ]))
    fix = check(report, "extraction").fix
    assert_match(/upgrade yt-dlp|YTDLP_PLAYER_CLIENTS/, fix)
    refute_match(/YTDLP_COOKIES/, fix)
  end

  # YouTube reports an unsolved JS challenge as a FORMAT error, which sends you
  # hunting a format selector that is not broken.
  test "a format error caused by the JS challenge points at the runtime and solver" do
    report = healthy_report(run: FakeRun.new([
      [ "-J", failed_run("ERROR: [youtube] x: Requested format is not available.") ]
    ]))
    fix = check(report, "extraction").fix
    assert_match(/YTDLP_JS_RUNTIMES/, fix)
    assert_match(/yt-dlp-ejs/, fix)
    refute_match(/YTDLP_COOKIES=/, fix)
  end

  test "the probe runs with the same JS runtime the pipeline downloads with" do
    seen = []
    recorder = Class.new do
      def initialize(seen) = @seen = seen
      def call(cmd, timeout: nil)
        @seen << cmd.join(" ")
        Diagnostics::RunResult.new(out: "ok", err: "", ok: true, missing: false)
      end
    end
    checks = healthy_report(
      run: recorder.new(seen),
      env: { "ANTHROPIC_API_KEY" => "x", "YTDLP_JS_RUNTIMES" => "node" }
    ).call
    assert_includes seen.find { |c| c.include?("-J") }, "--js-runtimes node"
    assert_match(/js: node/, checks.find { |c| c.name.include?("extraction") }.detail)
  end

  # A taken-down probe video is a fact about the video, not about the environment.
  test "a dead probe video sends you to DOCTOR_PROBE_URL, not to cookies" do
    report = healthy_report(run: FakeRun.new([
      [ "-J", failed_run("ERROR: [youtube] jNQXAC9IVRw: This video is unavailable") ]
    ]))
    fix = check(report, "extraction").fix
    assert_match(/DOCTOR_PROBE_URL/, fix)
    refute_match(/YTDLP_COOKIES/, fix)
  end

  test "rejected cookies are called out instead of being reported as absent" do
    report = healthy_report(
      run: FakeRun.new([ [ "-J", failed_run("Sign in to confirm you're not a bot") ] ]),
      env: { "ANTHROPIC_API_KEY" => "sk-ant-xxx", "YTDLP_COOKIES" => "/secrets/cookies.txt" }
    )
    assert_match(/were rejected/, check(report, "extraction").fix)
  end

  test "the extraction probe sends the configured cookies with the request" do
    seen = []
    recorder = Class.new do
      def initialize(seen) = @seen = seen
      def call(cmd, timeout: nil)
        @seen << cmd.join(" ")
        Diagnostics::RunResult.new(out: "ok", err: "", ok: true, missing: false)
      end
    end
    checks = healthy_report(
      run: recorder.new(seen),
      env: { "ANTHROPIC_API_KEY" => "x", "YTDLP_COOKIES" => "/secrets/cookies.txt" }
    ).call
    probe = seen.find { |c| c.include?("-J") }
    assert_includes probe, "--cookies /secrets/cookies.txt"
    assert_match(/cookies/, checks.find { |c| c.name.include?("extraction") }.detail)
  end

  # yt-dlp ignores an unreadable jar and retries anonymously, so a typo in the path
  # looks exactly like having no cookies at all — the doctor must not repeat that.
  test "an unreadable cookie jar is named, not silently degraded to anonymous" do
    report = healthy_report(
      env: { "ANTHROPIC_API_KEY" => "x", "YTDLP_COOKIES" => "/typo/cookies.txt" },
      readable: ->(_path) { false }
    )
    c = check(report, "extraction")
    assert c.failed?
    assert_match(%r{/typo/cookies\.txt}, c.detail)
    assert_match(/ignores an unreadable jar/, c.fix)
  end

  test "a browser profile is yt-dlp's to locate, so it is not readability-checked" do
    report = healthy_report(
      env: { "ANTHROPIC_API_KEY" => "x", "YTDLP_COOKIES_FROM_BROWSER" => "chrome" },
      readable: ->(_path) { flunk "a browser profile must not be probed as a file" }
    )
    assert check(report, "extraction").passed?
  end

  test "the extraction probe reports whether it ran anonymously" do
    assert_match(/anonymous/, check(healthy_report, "extraction").detail)
  end

  test "the probe video is overridable, since any fixed video can be taken down" do
    seen = []
    recorder = Class.new do
      def initialize(seen) = @seen = seen
      def call(cmd, timeout: nil)
        @seen << cmd.join(" ")
        Diagnostics::RunResult.new(out: "ok", err: "", ok: true, missing: false)
      end
    end
    healthy_report(
      run: recorder.new(seen),
      env: { "ANTHROPIC_API_KEY" => "sk-ant-xxx", "DOCTOR_PROBE_URL" => "https://youtu.be/zzzzzzzzzzz" }
    ).call
    assert seen.any? { |c| c.include?("zzzzzzzzzzz") }, "the probe should ask about the configured video"
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
