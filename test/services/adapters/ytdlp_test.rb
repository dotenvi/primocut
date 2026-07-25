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
end
