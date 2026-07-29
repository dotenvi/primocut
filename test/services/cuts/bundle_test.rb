require "test_helper"
require "tmpdir"
require "fileutils"

class Cuts::BundleTest < ActiveSupport::TestCase
  def setup
    project = Project.create!(name: "Niche")
    @video = project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    @cut = @video.cuts.create!(name: "Cut 1")
  end

  def with_exports_dir
    Dir.mktmpdir do |dir|
      ENV["EXPORTS_DIR"] = dir
      yield dir
    ensure
      ENV.delete("EXPORTS_DIR")
    end
  end

  def export!(zip_rel_path, state: "done")
    @cut.create_export!(source_video_id: @video.id, state:, zip_rel_path:, item_count: 1)
  end

  test "the finished bundle resolves to its file" do
    with_exports_dir do |dir|
      rel = "abcdefghijk/#{@cut.id}/best-20260101.zip"
      FileUtils.mkdir_p(File.join(dir, File.dirname(rel)))
      File.write(File.join(dir, rel), "ZIPBYTES")
      export!(rel)

      assert_equal File.join(dir, rel), Cuts::Bundle.new.call(cut: @cut)
    end
  end

  test "a row that says done is not proof the file is there" do
    with_exports_dir do
      export!("abcdefghijk/gone.zip")

      assert_raises(Cuts::Bundle::NotReady) { Cuts::Bundle.new.call(cut: @cut) }
    end
  end

  test "an unfinished export has no bundle" do
    with_exports_dir do
      export!("", state: "queued")

      assert_raises(Cuts::Bundle::NotReady) { Cuts::Bundle.new.call(cut: @cut) }
    end
  end

  # Nothing a request carries reaches this path — the export job writes it. The
  # guard is here so that a row pointing out of the exports directory is treated
  # as no bundle at all, instead of as permission to hand that file to a browser.
  test "a path escaping the exports directory is refused, even when the file exists" do
    with_exports_dir do |dir|
      outside = File.join(File.dirname(dir), "outside-#{SecureRandom.hex(4)}.zip")
      File.write(outside, "SECRET")
      export!("../#{File.basename(outside)}")

      assert_raises(Cuts::Bundle::NotReady) { Cuts::Bundle.new.call(cut: @cut) }
    ensure
      FileUtils.rm_f(outside)
    end
  end
end
