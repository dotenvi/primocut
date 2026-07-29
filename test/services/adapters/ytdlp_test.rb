require "test_helper"
require "tmpdir"

# Tests for the yt-dlp adapter — fully faked subprocess (no binary, no network).
# Covers the pure URL helpers, metadata parsing, and the download orchestration
# (player_client fallback, resume, source cleanup). Ported from the PoC
# `tests/test_download_audio.py`.
class Adapters::YtdlpTest < ActiveSupport::TestCase
  Ytdlp = Adapters::Ytdlp

  # Records every command; `capture`/`run` behaviour is supplied per test.
  class FakeShell
    attr_reader :calls

    def initialize(&handler)
      @calls = []
      @handler = handler
    end

    def capture(cmd)
      @calls << cmd
      @handler.call(:capture, cmd)
    end

    def run(cmd)
      @calls << cmd
      @handler.call(:run, cmd)
    end
  end

  # ------------------------- pure helpers -------------------------

  test "extract_video_id from the common URL shapes" do
    assert_equal "abcdefghijk", Ytdlp.extract_video_id("https://www.youtube.com/watch?v=abcdefghijk")
    assert_equal "abcdefghijk", Ytdlp.extract_video_id("https://youtu.be/abcdefghijk")
    assert_equal "abcdefghijk", Ytdlp.extract_video_id("https://www.youtube.com/live/abcdefghijk")
    assert_equal "abcdefghijk", Ytdlp.extract_video_id("https://www.youtube.com/shorts/abcdefghijk")
  end

  test "validate_youtube_url canonicalizes a valid link" do
    assert_equal "https://www.youtube.com/watch?v=abcdefghijk",
      Ytdlp.validate_youtube_url("https://youtu.be/abcdefghijk")
  end

  test "validate_youtube_url rejects non-YouTube and malformed links" do
    assert_raises(Ytdlp::Error) { Ytdlp.validate_youtube_url("https://vimeo.com/123") }
    assert_raises(Ytdlp::Error) { Ytdlp.validate_youtube_url("not a url") }
    assert_raises(Ytdlp::Error) { Ytdlp.validate_youtube_url("") }
    assert_raises(Ytdlp::Error) { Ytdlp.validate_youtube_url("https://www.youtube.com/watch?v=abc\\def") }
  end

  # ------------------------- metadata -------------------------

  test "fetch_metadata parses the yt-dlp -J envelope" do
    json = {
      "id" => "abcdefghijk", "webpage_url" => "https://www.youtube.com/watch?v=abcdefghijk",
      "title" => "Cool Live", "channel" => "Cool Channel", "duration" => 3725.7
    }.to_json
    shell = FakeShell.new { |_kind, _cmd| json }
    meta = Ytdlp.new(shell: shell).fetch_metadata("https://www.youtube.com/watch?v=abcdefghijk")

    assert_equal "abcdefghijk", meta.youtube_id
    assert_equal "Cool Live", meta.title
    assert_equal "Cool Channel", meta.channel
    assert_equal 3725, meta.duration_s
  end

  test "fetch_metadata degrades missing fields to sensible defaults" do
    shell = FakeShell.new { |_kind, _cmd| "{}" }
    meta = Ytdlp.new(shell: shell).fetch_metadata("https://youtu.be/abcdefghijk")

    assert_equal "abcdefghijk", meta.youtube_id
    assert_equal "(no title)", meta.title
    assert_equal "(unknown)", meta.channel
    assert_equal 0, meta.duration_s
  end

  # ------------------------- download -------------------------

  test "download_audio reuses an existing normalized WAV (resume)" do
    Dir.mktmpdir do |dir|
      wav = File.join(dir, "vid00000001.16k.wav")
      File.write(wav, "cached")
      shell = FakeShell.new { |_kind, _cmd| flunk "should not shell out on resume" }

      path = Ytdlp.new(shell: shell).download_audio("https://y/1", dir, video_id: "vid00000001")

      assert_equal wav, path.to_s
      assert_empty shell.calls
    end
  end

  test "download_audio falls back across player clients then normalizes" do
    Dir.mktmpdir do |dir|
      seen_clients = []
      shell = FakeShell.new do |_kind, cmd|
        if cmd.include?("bestaudio/best")
          client = cmd.each_cons(2).find { |a, _| a == "--extractor-args" }&.last
          seen_clients << client
          raise Adapters::Shell::CommandError, "extractor broke" if seen_clients.size == 1

          File.write(File.join(dir, "vid00000001.src.webm"), "audio")
        elsif cmd.include?("-ar")
          assert File.exist?(File.join(dir, "vid00000001.src.webm")), "ffmpeg runs after download"
          File.write(File.join(dir, "vid00000001.16k.wav"), "wav")
        end
      end

      adapter = Ytdlp.new(shell: shell, player_clients: %w[web android])
      path = adapter.download_audio("https://y/1", dir, video_id: "vid00000001")

      assert_equal File.join(dir, "vid00000001.16k.wav"), path.to_s
      assert_equal [ "youtube:player_client=web", "youtube:player_client=android" ], seen_clients
      assert_not File.exist?(File.join(dir, "vid00000001.src.webm")), "source is cleaned up"
    end
  end

  test "download_audio raises when every player client fails" do
    Dir.mktmpdir do |dir|
      shell = FakeShell.new do |_kind, cmd|
        raise Adapters::Shell::CommandError, "boom" if cmd.include?("bestaudio/best")
      end
      adapter = Ytdlp.new(shell: shell, player_clients: %w[web android])
      assert_raises(Ytdlp::Error) { adapter.download_audio("https://y/1", dir, video_id: "vid00000001") }
    end
  end

  # ------------------------- cookies -------------------------

  test "default_cookie_args is empty when neither variable is set" do
    assert_empty Ytdlp.default_cookie_args({})
  end

  test "default_cookie_args reads a browser profile" do
    args = Ytdlp.default_cookie_args("YTDLP_COOKIES_FROM_BROWSER" => "firefox:default")
    assert_equal [ "--cookies-from-browser", "firefox:default" ], args
  end

  # The file wins because --cookies-from-browser reads a LOCAL profile: under WSL2
  # it finds nothing when the browser lives on the Windows side.
  test "an exported cookie file wins over a browser profile" do
    args = Ytdlp.default_cookie_args(
      "YTDLP_COOKIES" => "/secrets/cookies.txt", "YTDLP_COOKIES_FROM_BROWSER" => "chrome"
    )
    assert_equal [ "--cookies", "/secrets/cookies.txt" ], args
  end

  test "blank variables are treated as unset, not as an empty flag value" do
    assert_empty Ytdlp.default_cookie_args("YTDLP_COOKIES" => "   ", "YTDLP_COOKIES_FROM_BROWSER" => "")
  end

  test "default_js_runtime_args is empty, leaving yt-dlp's own default" do
    assert_empty Ytdlp.default_js_runtime_args({})
  end

  test "default_js_runtime_args names the runtime to enable" do
    assert_equal [ "--js-runtimes", "node" ], Ytdlp.default_js_runtime_args("YTDLP_JS_RUNTIMES" => "node")
  end

  # The bot-check hits metadata, audio and sections alike, so a cookie jar that
  # reaches only some of them still leaves the pipeline broken somewhere. The JS
  # runtime rides along for the same reason: the challenge gates every one of them.
  test "cookies and the JS runtime reach metadata, the audio and the section download" do
    cookies = [ "--cookies", "/secrets/cookies.txt" ]
    js = [ "--js-runtimes", "node" ]

    Dir.mktmpdir do |dir|
      seen = []
      shell = FakeShell.new do |kind, cmd|
        seen << cmd
        next '{"id":"abcdefghijk"}' if kind == :capture

        File.write(File.join(dir, "section.mkv"), "sec") if cmd.include?("--force-keyframes-at-cuts")
        File.write(File.join(dir, "vid00000001.src.webm"), "audio") if cmd.include?("bestaudio/best")
        File.write(File.join(dir, "vid00000001.16k.wav"), "wav") if cmd.include?("-ar")
      end
      adapter = Ytdlp.new(shell: shell, cookie_args: cookies, js_runtime_args: js)

      adapter.fetch_metadata("https://y/1")
      adapter.download_audio("https://y/1", dir, video_id: "vid00000001")
      adapter.download_section("https://y/1", dir, start_s: 1.0, end_s: 2.0, margin_s: 0.0, duration: 0.0)

      ytdlp_calls = seen.reject { |cmd| cmd.include?("-ar") } # the ffmpeg pass takes neither
      assert_equal 3, ytdlp_calls.size
      ytdlp_calls.each do |cmd|
        assert_equal cookies, cmd.each_cons(2).find { |a, _| a == "--cookies" },
          "missing the cookie jar in: #{cmd.join(' ')}"
        assert_equal js, cmd.each_cons(2).find { |a, _| a == "--js-runtimes" },
          "missing the JS runtime in: #{cmd.join(' ')}"
      end
    end
  end

  # ------------------------- section download -------------------------

  test "section_bounds widens by the margin and clamps to the duration" do
    assert_equal [ 85.0, 215.0 ], Ytdlp.section_bounds(100.0, 200.0, 15.0, 600.0)
    assert_equal [ 0.0, 35.0 ], Ytdlp.section_bounds(5.0, 20.0, 15.0, 600.0)   # clamps start to 0
    assert_equal [ 85.0, 205.0 ], Ytdlp.section_bounds(100.0, 200.0, 15.0, 205.0) # clamps to duration
    assert_equal [ 85.0, 215.0 ], Ytdlp.section_bounds(100.0, 200.0, 15.0, 0.0)  # unknown duration
  end

  test "download_section builds the exact-cut command and returns the file" do
    Dir.mktmpdir do |dir|
      cmd_seen = nil
      shell = FakeShell.new do |_kind, cmd|
        cmd_seen = cmd
        File.write(File.join(dir, "section.mkv"), "sec")
      end

      path = Ytdlp.new(shell: shell)
        .download_section("https://y/1", dir, start_s: 100.0, end_s: 200.0, margin_s: 15.0, duration: 600.0)

      assert_equal File.join(dir, "section.mkv"), path.to_s
      assert_includes cmd_seen, "--force-keyframes-at-cuts"
      assert_includes cmd_seen, "*85.000-215.000"
      assert_includes cmd_seen, "bv*+ba/b"
    end
  end

  test "download_section falls back across player clients" do
    Dir.mktmpdir do |dir|
      seen = []
      shell = FakeShell.new do |_kind, cmd|
        client = cmd.each_cons(2).find { |a, _| a == "--extractor-args" }&.last
        seen << client
        raise Adapters::Shell::CommandError, "extractor broke" if seen.size == 1

        File.write(File.join(dir, "section.mkv"), "sec")
      end

      path = Ytdlp.new(shell: shell, player_clients: %w[web android])
        .download_section("https://y/1", dir, start_s: 10.0, end_s: 20.0, margin_s: 5.0, duration: 0.0)

      assert_equal File.join(dir, "section.mkv"), path.to_s
      assert_equal [ "youtube:player_client=web", "youtube:player_client=android" ], seen
    end
  end

  test "download_section raises when every player client fails" do
    Dir.mktmpdir do |dir|
      shell = FakeShell.new { raise Adapters::Shell::CommandError, "boom" }
      adapter = Ytdlp.new(shell: shell, player_clients: %w[web android])
      assert_raises(Ytdlp::Error) do
        adapter.download_section("https://y/1", dir, start_s: 10.0, end_s: 20.0, margin_s: 5.0, duration: 0.0)
      end
    end
  end
end
