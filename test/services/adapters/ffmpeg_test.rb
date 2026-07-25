require "test_helper"
require "tmpdir"

# Tests for the FFmpeg adapter — fully faked subprocess (no binary, no GPU). The
# fake records commands and, for frame extraction, materializes the JPEGs FFmpeg
# would produce. Ported from the PoC `tests/test_render.py`.
class Adapters::FfmpegTest < ActiveSupport::TestCase
  Ffmpeg = Adapters::Ffmpeg

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

  # ------------------------- nvenc pre-check -------------------------

  test "nvenc_listed? reflects the encoders listing" do
    yes = Ffmpeg.new(shell: FakeShell.new { "…\n V..... h264_nvenc NVIDIA\n" })
    assert yes.nvenc_listed?

    no = Ffmpeg.new(shell: FakeShell.new { " V..... libx264 …\n" })
    assert_not no.nvenc_listed?
  end

  test "nvenc_listed? is false when ffmpeg is missing" do
    ff = Ffmpeg.new(shell: FakeShell.new { raise Errno::ENOENT, "ffmpeg" })
    assert_not ff.nvenc_listed?
  end

  # ------------------------- encode -------------------------

  test "encode_clip copy profile stream-copies and reports copy" do
    Dir.mktmpdir do |dir|
      cmds = []
      shell = FakeShell.new { |_k, cmd| cmds << cmd }
      out = File.join(dir, "001-clip.mp4")

      encoder, warning = Ffmpeg.new(shell: shell)
        .encode_clip("section.mkv", out, local_start: 1.5, local_dur: 5.0, profile: "copy")

      assert_equal "copy", encoder
      assert_nil warning
      assert_includes cmds.last, "-c"
      assert_includes cmds.last, "copy"
      assert_includes cmds.last, "1.500"
      assert_includes cmds.last, "5.000"
    end
  end

  test "encode_clip nvenc succeeds without a warning" do
    encoder, warning = Ffmpeg.new(shell: FakeShell.new { nil })
      .encode_clip("s.mkv", "o.mp4", local_start: 0, local_dur: 3, profile: "nvenc")
    assert_equal "nvenc", encoder
    assert_nil warning
  end

  test "encode_clip falls back from nvenc to libx264 with a warning" do
    shell = FakeShell.new do |_k, cmd|
      raise Adapters::Shell::CommandError, "no nvenc" if cmd.include?("h264_nvenc")
    end
    encoder, warning = Ffmpeg.new(shell: shell)
      .encode_clip("s.mkv", "o.mp4", local_start: 0, local_dur: 3, profile: "nvenc")
    assert_equal "libx264", encoder
    assert_match(/fell back to libx264/, warning)
  end

  test "encode_clip with an explicit profile has no fallback" do
    shell = FakeShell.new { raise Adapters::Shell::CommandError, "boom" }
    assert_raises(Ffmpeg::Error) do
      Ffmpeg.new(shell: shell).encode_clip("s.mkv", "o.mp4", local_start: 0, local_dur: 3, profile: "libx264")
    end
  end

  # ------------------------- probe -------------------------

  test "probe_duration parses the ffprobe number, else 0.0" do
    assert_equal 42.5, Ffmpeg.new(shell: FakeShell.new { "42.5\n" }).probe_duration("c.mp4")
    assert_equal 0.0, Ffmpeg.new(shell: FakeShell.new { "N/A\n" }).probe_duration("c.mp4")
  end

  # ------------------------- frames -------------------------

  def frame_shell(dir, scene_count:, duration: 10.0)
    FakeShell.new do |kind, cmd|
      next "#{duration}\n" if kind == :capture # ffprobe

      if cmd.include?("-vsync") # scene detection pass
        scene_count.times { |i| File.write(File.join(dir, format("scene-%03d.jpg", i + 1)), "s") }
      elsif cmd.include?("-frames:v") # single sample
        File.write(cmd.last, "f")
      end
    end
  end

  test "extract_frames promotes scenes then fills with samples" do
    Dir.mktmpdir do |dir|
      names = Ffmpeg.new(shell: frame_shell(dir, scene_count: 2))
        .extract_frames("clip.mp4", dir, count: 3, scene_threshold: 0.3)

      assert_equal %w[frame-001.jpg frame-002.jpg frame-003.jpg], names
      assert_empty Dir.glob(File.join(dir, "scene-*.jpg")), "scene leftovers are cleaned"
    end
  end

  test "extract_frames uses samples only when there are no scenes" do
    Dir.mktmpdir do |dir|
      names = Ffmpeg.new(shell: frame_shell(dir, scene_count: 0))
        .extract_frames("clip.mp4", dir, count: 2, scene_threshold: 0.3)
      assert_equal %w[frame-001.jpg frame-002.jpg], names
    end
  end

  test "extract_frames is pay-once by presence" do
    Dir.mktmpdir do |dir|
      3.times { |i| File.write(File.join(dir, format("frame-%03d.jpg", i + 1)), "old") }
      shell = FakeShell.new { flunk "should not shell out on a cache hit" }

      names = Ffmpeg.new(shell: shell).extract_frames("clip.mp4", dir, count: 3, scene_threshold: 0.3)
      assert_equal %w[frame-001.jpg frame-002.jpg frame-003.jpg], names
    end
  end

  test "extract_frames regenerate rebuilds even a full set" do
    Dir.mktmpdir do |dir|
      3.times { |i| File.write(File.join(dir, format("frame-%03d.jpg", i + 1)), "old") }
      shell = frame_shell(dir, scene_count: 1)

      names = Ffmpeg.new(shell: shell)
        .extract_frames("clip.mp4", dir, count: 2, scene_threshold: 0.3, regenerate: true)
      assert_equal %w[frame-001.jpg frame-002.jpg], names
    end
  end
end
