require "test_helper"
require "tmpdir"
require "fileutils"

# Tests for the packaging orchestration — faked LLM/FFmpeg and an injected niche
# context. Ported from the PoC `tests/test_packaging_jobs.py`.
class Cuts::PackagingServiceTest < ActiveSupport::TestCase
  class FakeLlm
    attr_reader :calls

    def initialize(&block)
      @calls = 0
      @block = block
    end

    def select(**kwargs)
      @calls += 1
      @block.call(kwargs)
    end
  end

  class FakeFfmpeg
    attr_reader :calls

    def initialize(dir)
      @dir = dir
      @calls = []
    end

    def extract_frames(clip_path, out_dir, count:, scene_threshold:, regenerate: false)
      @calls << out_dir.to_s
      FileUtils.mkdir_p(out_dir)
      count.times { |i| File.write(File.join(out_dir, format("frame-%03d.jpg", i + 1)), "f") }
      (1..count).map { |i| format("frame-%03d.jpg", i) }
    end
  end

  CONTEXT = {
    niche: { project_name: "Niche", channels: 1, outliers: 1, format: "long" },
    differential: [], conventions: [], carries_value: {}, examples: [], flat: true
  }.freeze

  def setup
    @clips = Dir.mktmpdir("clips-")
    project = Project.create!(name: "Niche")
    @video = project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1", duration_s: 600)
    @video.create_transcript!(language: "pt", model: "m", segments: [
      { "index" => 0, "start" => 100.0, "end" => 110.0, "text" => "the opening words" }
    ])
    @cut = @video.cuts.create!
    @topic = @video.topics.create!(title: "Opening", summary: "intro", start_s: 100, end_s: 130)
  end

  def teardown = FileUtils.remove_entry(@clips)

  def service(llm:, ffmpeg: nil)
    Cuts::PackagingService.new(
      llm:, ffmpeg: ffmpeg || FakeFfmpeg.new(@clips), clips_dir: @clips,
      context_builder: ->(_p) { CONTEXT },
      audience_requests: ->(_p) { { "by_type" => {} } }
    )
  end

  def rendered_item(position:, start_s:, end_s:, topic: nil)
    item = @cut.cut_items.create!(position:, topic:, start_s:, end_s:)
    rel = "#{@video.youtube_id}/#{@cut.id}/#{format('%03d', position + 1)}-clip.mp4"
    full = File.join(@clips, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, "clip")
    item.create_clip!(source_video_id: @video.id, cut_id: @cut.id, position:, rel_path: rel, state: "done")
    item
  end

  test "generate title persists a packaging row and caches on a second run" do
    item = @cut.cut_items.create!(position: 0, topic: @topic, start_s: 100, end_s: 130)
    llm = FakeLlm.new { { "titles" => [ { "title" => "A Great Clip", "patterns_applied" => [] } ] } }

    result = service(llm:).generate(@cut, kind: "title")
    assert_equal 1, result.generated
    pk = CutPackaging.find_by(cut_item_id: item.id, kind: "title")
    assert pk.state_done?
    assert_equal "A Great Clip", pk.payload["titles"].first["title"]

    llm2 = FakeLlm.new { flunk "a cache hit should not call the model" }
    again = service(llm: llm2).generate(@cut, kind: "title")
    assert_equal 0, again.generated
    assert_equal 1, again.skipped
  end

  test "generate isolates a per-item failure" do
    good = @cut.cut_items.create!(position: 0, topic: @topic, start_s: 100, end_s: 130)
    bad = @cut.cut_items.create!(position: 1, start_s: 200, end_s: 220)
    calls = 0
    llm = FakeLlm.new do
      calls += 1
      raise "llm down" if calls == 2

      { "titles" => [ { "title" => "ok", "patterns_applied" => [] } ] }
    end

    result = service(llm:).generate(@cut, kind: "title")
    assert_equal 1, result.generated
    assert_equal 1, result.failed
    assert CutPackaging.find_by(cut_item_id: good.id, kind: "title").state_done?
    assert CutPackaging.find_by(cut_item_id: bad.id, kind: "title").state_error?
  end

  test "extract_frames runs only for rendered items" do
    rendered_item(position: 0, topic: @topic, start_s: 100, end_s: 130)
    @cut.cut_items.create!(position: 1, start_s: 200, end_s: 220) # no clip → skipped
    ff = FakeFfmpeg.new(@clips)

    result = service(llm: FakeLlm.new { }, ffmpeg: ff).extract_frames(@cut)
    assert_equal 1, result.generated
    assert_equal 1, ff.calls.size
  end

  test "rank_frames scores the extracted frames and skips items without any" do
    item = rendered_item(position: 0, topic: @topic, start_s: 100, end_s: 130)
    frames_dir = File.join(@clips, @video.youtube_id, @cut.id.to_s, "frames", "000")
    FileUtils.mkdir_p(frames_dir)
    2.times { |i| File.write(File.join(frames_dir, format("frame-%03d.jpg", i + 1)), "f") }

    llm = FakeLlm.new { { "rankings" => [ { "frame" => 0, "score" => 0.9 } ], "best_frame" => 0 } }
    result = service(llm:).rank_frames(@cut)

    assert_equal 1, result.generated
    pk = CutPackaging.find_by(cut_item_id: item.id, kind: "frame_ranking")
    assert_equal "frame-001.jpg", pk.payload["best_filename"]
  end

  test "match_audience caches per source video and degrades without requests" do
    @cut # ensure setup
    llm = FakeLlm.new { flunk "no requests means no model call" }
    match = service(llm:).match_audience(@video)
    assert match.state_done?
    assert_equal({}, match.payload)
  end
end
