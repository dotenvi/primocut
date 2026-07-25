require "test_helper"
require "tmpdir"
require "fileutils"
require "zip"

# Tests for the cut export — real file IO in temp dirs, faked FFmpeg master.
# Ported from the PoC `tests/test_export_jobs.py`.
class Cuts::ExportTest < ActiveSupport::TestCase
  class FakeFfmpeg
    attr_reader :master_calls, :upscale_height

    def initialize
      @master_calls = []
      @upscale_height = 1440
    end

    def concat_master(filenames, out, cwd:, upscale: false)
      @master_calls << { filenames:, cwd: cwd.to_s, upscale: }
      File.write(out, "master-bytes")
      [ upscale ? "nvenc" : "copy", nil ]
    end
  end

  def setup
    @clips = Dir.mktmpdir("clips-")
    @exports = Dir.mktmpdir("exports-")
    project = Project.create!(name: "Niche")
    @video = project.source_videos.create!(
      youtube_id: "abcdefghijk", url: "https://y/1", title: "Cool Live",
      channel: "Cool Channel", duration_s: 600
    )
    @video.create_transcript!(language: "pt", model: "m", segments: [
      { "index" => 0, "start" => 100.0, "end" => 105.0, "text" => "hello" }
    ])
    @cut = @video.cuts.create!(name: "Best Of")
    @topic = @video.topics.create!(title: "Opening Bell", start_s: 100, end_s: 130)
  end

  def teardown
    FileUtils.remove_entry(@clips)
    FileUtils.remove_entry(@exports)
  end

  # Create a cut item and its rendered clip file on disk.
  def rendered_item(position:, start_s:, end_s:, topic: nil, state: "done")
    item = @cut.cut_items.create!(position:, topic:, start_s:, end_s:)
    filename = "#{format('%03d', position + 1)}-clip.mp4"
    rel_path = "#{@video.youtube_id}/#{@cut.id}/#{filename}"
    full = File.join(@clips, rel_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, "clip-#{position}")
    item.create_clip!(
      source_video_id: @video.id, cut_id: @cut.id, position:, filename:, rel_path:,
      state:, render_start_s: start_s, render_end_s: end_s, start_s:, end_s:
    )
    item
  end

  def export(**over)
    Cuts::Export.new(ffmpeg: FakeFfmpeg.new, clips_dir: @clips, exports_dir: @exports, **over)
  end

  test "packages clips, SRTs, master and manifests into a zipped bundle" do
    rendered_item(position: 0, topic: @topic, start_s: 100, end_s: 130)
    rendered_item(position: 1, start_s: 200, end_s: 220)

    result = export.call(@cut)

    assert_equal "done", result.state
    assert_equal 2, result.item_count
    assert result.master

    row = @cut.reload.export
    assert row.state_done?
    pkg = File.join(@exports, row.package_rel_path)
    assert File.exist?(File.join(pkg, "001-opening-bell.mp4"))
    assert File.exist?(File.join(pkg, "002-manual-range.mp4"))
    assert File.exist?(File.join(pkg, "master.mp4"))
    assert File.exist?(File.join(pkg, "manifest.json"))
    assert File.exist?(File.join(pkg, "manifest.md"))
    # The first clip's SRT carries the overlapping transcript line, clip-relative.
    assert_includes File.read(File.join(pkg, "001-opening-bell.srt")), "hello"

    zip = File.join(@exports, row.zip_rel_path)
    assert File.exist?(zip)
    names = Zip::File.open(zip) { |z| z.map(&:name) }
    assert_includes names, "manifest.json"
  end

  test "the original clip files are copied, never moved" do
    item = rendered_item(position: 0, topic: @topic, start_s: 100, end_s: 130)
    export.call(@cut)
    assert File.exist?(File.join(@clips, item.clip.rel_path)), "the source clip stays put"
  end

  test "an empty cut is a recorded failure" do
    result = export.call(@cut)
    assert_equal "error", result.state
    assert_match(/no items/, result.error)
    assert @cut.reload.export.state_error?
  end

  test "unrendered items fail clearly by default" do
    rendered_item(position: 0, topic: @topic, start_s: 100, end_s: 130, state: "queued")
    result = export.call(@cut)
    assert_equal "error", result.state
    assert_match(/not rendered/, result.error)
  end

  test "render_missing renders the missing items first, then packages" do
    item = @cut.cut_items.create!(position: 0, topic: @topic, start_s: 100, end_s: 130)
    fake_render = Object.new
    fake_render.define_singleton_method(:call) do |cut, item_ids:|
      # Simulate the render service producing the clip on disk + row.
      rel = "#{cut.source_video.youtube_id}/#{cut.id}/001-clip.mp4"
      full = File.join(ENV["__TEST_CLIPS"], rel)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, "rendered")
      cut.cut_items.find(item_ids.first).create_clip!(
        source_video_id: cut.source_video_id, cut_id: cut.id, position: 0,
        rel_path: rel, state: "done", render_start_s: 100, render_end_s: 130
      )
    end
    ENV["__TEST_CLIPS"] = @clips

    result = export(render_service: fake_render).call(@cut, render_missing: true)

    assert_equal "done", result.state
    assert item.reload.clip.state_done?
  ensure
    ENV.delete("__TEST_CLIPS")
  end

  test "upscale cannot be combined with skipping the master" do
    rendered_item(position: 0, topic: @topic, start_s: 100, end_s: 130)
    result = export.call(@cut, upscale: true, skip_master: true)
    assert_equal "error", result.state
    assert_match(/needs the master/, result.error)
  end

  test "skip_master leaves out the master" do
    rendered_item(position: 0, topic: @topic, start_s: 100, end_s: 130)
    result = export.call(@cut, skip_master: true)
    assert_not result.master
    pkg = File.join(@exports, @cut.reload.export.package_rel_path)
    assert_not File.exist?(File.join(pkg, "master.mp4"))
  end
end
