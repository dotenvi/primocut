require "test_helper"
require "tmpdir"
require "fileutils"

# Tests for the clip-render service — fully faked yt-dlp/FFmpeg (no network, no
# GPU). Ported from the PoC `tests/test_render_jobs.py`. Covers the pay-once
# cache, the reorder rename, per-item isolation and the optional align seam.
class Cuts::RenderTest < ActiveSupport::TestCase
  # Writes a stand-in section file; can be told to fail a given item's start.
  class FakeYtdlp
    def initialize(fail_starts: [])
      @fail_starts = fail_starts
    end

    def download_section(_url, dir, start_s:, end_s:, margin_s:, duration:)
      raise Adapters::Ytdlp::Error, "extractor broke" if @fail_starts.include?(start_s)

      path = Pathname(dir).join("section.mkv")
      File.write(path, "sec")
      path
    end
  end

  # Writes a stand-in MP4 and records each encode call.
  class FakeFfmpeg
    attr_reader :calls

    def initialize(encoder: "nvenc")
      @encoder = encoder
      @calls = []
    end

    def encode_clip(_section, out, local_start:, local_dur:, profile:)
      @calls << { out: out.to_s, local_start:, local_dur:, profile: }
      FileUtils.mkdir_p(File.dirname(out))
      File.write(out, "mp4-bytes")
      [ profile == "copy" ? "copy" : @encoder, nil ]
    end
  end

  # A boundary refiner that snaps both edges inward by 1s and records its calls.
  class FakeAligner
    attr_reader :calls

    def initialize = (@calls = [])
    def tolerance_s = 3.0

    def refine_bounds(section:, s0:, start_s:, end_s:, workdir:)
      @calls << { s0:, start_s:, end_s: }
      [ start_s + 1.0, end_s - 1.0 ]
    end
  end

  def setup
    project = Project.create!(name: "Niche")
    @video = project.source_videos.create!(
      youtube_id: "abcdefghijk", url: "https://y/1", duration_s: 600
    )
    @cut = @video.cuts.create!
    @topic = @video.topics.create!(title: "Opening Bell", start_s: 100, end_s: 130)
  end

  def render(dir, **kwargs)
    Cuts::Render.new(
      ytdlp: kwargs.delete(:ytdlp) || FakeYtdlp.new,
      ffmpeg: kwargs.delete(:ffmpeg) || FakeFfmpeg.new,
      clips_dir: dir, **kwargs
    )
  end

  test "renders each item to a done clip with a file on disk" do
    Dir.mktmpdir do |dir|
      topic_item = @cut.cut_items.create!(position: 0, topic: @topic, start_s: 100, end_s: 130)
      manual = @cut.cut_items.create!(position: 1, start_s: 200, end_s: 220)

      result = render(dir).call(@cut)

      assert_equal 2, result.rendered
      assert_equal 0, result.skipped
      topic_item.reload
      assert topic_item.clip.state_done?
      assert_equal "001-opening-bell.mp4", topic_item.clip.filename
      assert_equal "abcdefghijk/#{@cut.id}/001-opening-bell.mp4", topic_item.clip.rel_path
      assert File.exist?(File.join(dir, topic_item.clip.rel_path))
      assert_equal "002-manual-range.mp4", manual.reload.clip.filename
    end
  end

  test "pay-once cache skips an unchanged item on a second call" do
    Dir.mktmpdir do |dir|
      @cut.cut_items.create!(position: 0, topic: @topic, start_s: 100, end_s: 130)

      first = render(dir, ffmpeg: (ff1 = FakeFfmpeg.new)).call(@cut)
      assert_equal 1, first.rendered
      assert_equal 1, ff1.calls.size

      second = render(dir, ffmpeg: (ff2 = FakeFfmpeg.new)).call(@cut)
      assert_equal 0, second.rendered
      assert_equal 1, second.skipped
      assert_empty ff2.calls, "a cache hit re-encodes nothing"
    end
  end

  test "a pure reorder renames the file without re-encoding" do
    Dir.mktmpdir do |dir|
      item = @cut.cut_items.create!(position: 0, topic: @topic, start_s: 100, end_s: 130)
      render(dir).call(@cut)
      old_path = File.join(dir, item.reload.clip.rel_path)
      assert File.exist?(old_path)

      item.update!(position: 4)
      result = render(dir, ffmpeg: (ff = FakeFfmpeg.new)).call(@cut)

      assert_equal 1, result.skipped
      assert_empty ff.calls
      clip = item.reload.clip
      assert_equal "005-opening-bell.mp4", clip.filename
      assert File.exist?(File.join(dir, clip.rel_path))
      assert_not File.exist?(old_path), "the old NNN file is gone after the rename"
    end
  end

  test "regenerate forces a re-encode of a cached item" do
    Dir.mktmpdir do |dir|
      @cut.cut_items.create!(position: 0, topic: @topic, start_s: 100, end_s: 130)
      render(dir).call(@cut)

      result = render(dir, ffmpeg: (ff = FakeFfmpeg.new)).call(@cut, regenerate: true)
      assert_equal 1, result.rendered
      assert_equal 1, ff.calls.size
    end
  end

  test "per-item isolation: one failure is flagged, the rest render" do
    Dir.mktmpdir do |dir|
      good = @cut.cut_items.create!(position: 0, topic: @topic, start_s: 100, end_s: 130)
      bad = @cut.cut_items.create!(position: 1, start_s: 200, end_s: 220)

      result = render(dir, ytdlp: FakeYtdlp.new(fail_starts: [ 200.0 ])).call(@cut)

      assert_equal 1, result.rendered
      assert_equal 1, result.failed
      assert good.reload.clip.state_done?
      assert bad.reload.clip.state_error?
      assert_match(/extractor broke/, bad.clip.error)
    end
  end

  test "fast_copy renders with the copy profile" do
    Dir.mktmpdir do |dir|
      @cut.cut_items.create!(position: 0, topic: @topic, start_s: 100, end_s: 130)
      ff = FakeFfmpeg.new
      render(dir, ffmpeg: ff).call(@cut, fast_copy: true)
      assert_equal "copy", ff.calls.first[:profile]
    end
  end

  test "the align seam refines the effective encoded window" do
    Dir.mktmpdir do |dir|
      item = @cut.cut_items.create!(position: 0, topic: @topic, start_s: 100, end_s: 130)
      aligner = FakeAligner.new
      ff = FakeFfmpeg.new

      render(dir, ffmpeg: ff, aligner: aligner).call(@cut)

      assert_equal 1, aligner.calls.size
      clip = item.reload.clip
      assert_equal 101.0, clip.render_start_s
      assert_equal 129.0, clip.render_end_s
      # local_start = r_start - s0, s0 = max(0, 100 - 15) = 85 → 101 - 85 = 16.
      assert_in_delta 16.0, ff.calls.first[:local_start], 0.001
      assert_in_delta 28.0, ff.calls.first[:local_dur], 0.001
    end
  end
end
