require "test_helper"

# The concatenated master — the cut as ONE file, built from the rendered clips with
# a stream copy. It is what the room plays, so it is offered only when a file for
# THIS composition is actually there.
class Cuts::MasterTest < ActiveSupport::TestCase
  # Writes the bytes instead of shelling out to FFmpeg, and records how it was
  # called — the concat listing's order is the composition's order, which is the
  # whole point of the file.
  class FakeConcat
    attr_reader :calls

    def initialize = @calls = []

    def concat_master(filenames, out, cwd:, upscale: false)
      @calls << { filenames: filenames, cwd: cwd.to_s, upscale: upscale }
      Pathname(out).dirname.mkpath
      File.write(out, "master bytes")
      [ "copy", nil ]
    end
  end

  setup do
    @dir = Dir.mktmpdir("primocut-clips-")
    @project = Project.create!(name: "Chess")
    @video = @project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    @cut = @video.cuts.create!(name: "Cut 1")
    @ffmpeg = FakeConcat.new
  end

  teardown { FileUtils.remove_entry(@dir) if File.exist?(@dir) }

  # A rendered item: the clip file on disk plus the row that points at it.
  def item!(position:, state: "done", params_hash: nil, write_file: true)
    it = @cut.cut_items.create!(position:, start_s: position * 100, end_s: (position * 100) + 10)
    rel = "#{@video.youtube_id}/#{@cut.id}/#{format('%03d-clip.mp4', position + 1)}"
    if write_file
      FileUtils.mkdir_p(File.dirname(File.join(@dir, rel)))
      File.write(File.join(@dir, rel), "clip")
    end
    it.create_clip!(cut_id: @cut.id, source_video_id: @video.id, state:, rel_path: rel,
                    position:, params_hash: params_hash || "hash#{position}")
    it
  end

  def master = Cuts::Master.new(ffmpeg: @ffmpeg, clips_dir: @dir)

  test "builds the cut by concatenating its clips in composition order" do
    item!(position: 0)
    item!(position: 1)
    item!(position: 2)

    out = master.build(@cut)

    assert_equal 1, @ffmpeg.calls.size
    assert_equal %w[001-clip.mp4 002-clip.mp4 003-clip.mp4], @ffmpeg.calls.first[:filenames]
    refute @ffmpeg.calls.first[:upscale], "playback is a stream copy, never a re-encode"
    assert File.exist?(out)
    assert_equal out.to_s, master.path_for(@cut).to_s
  end

  test "the clips are concatenated where they live, so the listing stays relative" do
    item!(position: 0)
    master.build(@cut)

    assert_equal File.join(@dir, @video.youtube_id, @cut.id.to_s), @ffmpeg.calls.first[:cwd]
  end

  test "an already-built master is not built twice" do
    item!(position: 0)
    first = master.build(@cut)
    again = master.build(@cut)

    assert_equal first.to_s, again.to_s
    assert_equal 1, @ffmpeg.calls.size, "the pay-once cache should have served it"
  end

  # A master missing an item would silently misrepresent the composition, so a
  # partly rendered cut gets none at all.
  test "a cut with an unrendered item has no master, and none is built" do
    item!(position: 0)
    item!(position: 1, state: "cutting")

    assert_nil master.build(@cut)
    assert_nil master.path_for(@cut)
    assert_empty @ffmpeg.calls
  end

  test "a cut with no items has no master" do
    assert_nil master.build(@cut)
    assert_nil master.path_for(@cut)
  end

  # ---- the composition's identity ----

  test "reordering the items invalidates the master" do
    a = item!(position: 0)
    b = item!(position: 1)
    stale = master.build(@cut)

    a.update!(position: 1)
    b.update!(position: 0)

    assert_nil master.path_for(@cut.reload), "the old file is not this composition"
    assert_not_equal stale.to_s, master.build(@cut.reload).to_s
  end

  test "re-rendering an item with different parameters invalidates the master" do
    item = item!(position: 0)
    stale = master.build(@cut)

    item.clip.update!(params_hash: "different")

    assert_nil master.path_for(@cut.reload)
    assert_not_equal stale.to_s, master.build(@cut.reload).to_s
  end

  # Each of these is a gigabyte-scale file; leaving them behind would fill the disk
  # one edit at a time.
  test "building a new master removes the one it supersedes" do
    item = item!(position: 0)
    stale = master.build(@cut)
    item.clip.update!(params_hash: "different")
    fresh = master.build(@cut.reload)

    refute File.exist?(stale), "the superseded master should be gone"
    assert File.exist?(fresh)
    assert_equal 1, Dir.glob(File.join(@dir, @video.youtube_id, @cut.id.to_s, "master-*.mp4")).size
  end

  test "a master whose file was deleted is not offered" do
    item!(position: 0)
    out = master.build(@cut)
    File.delete(out)

    assert_nil master.path_for(@cut), "files live outside the database and can be cleared"
  end

  test "call refuses instead of returning nil, for the request path" do
    assert_raises(Cuts::Master::NotReady) { master.call(cut: @cut) }
  end
end
