require "test_helper"

class CutExportJobTest < ActiveSupport::TestCase
  class FakeService
    attr_reader :calls

    def initialize = (@calls = [])

    def call(cut, render_missing:, skip_master:, upscale:, make_zip:)
      @calls << { cut:, render_missing:, skip_master:, upscale:, make_zip: }
      Cuts::Export::Result.new(cut:, state: "done", item_count: 0, package_rel_path: "",
                               zip_rel_path: "", master: false, upscaled: false, error: nil)
    end
  end

  test "loads the cut and delegates to the export service" do
    project = Project.create!(name: "Niche")
    video = project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    cut = video.cuts.create!
    service = FakeService.new

    CutExportJob.perform_now(cut.id, upscale: true, service:)

    assert_equal 1, service.calls.size
    assert_equal cut, service.calls.first[:cut]
    assert service.calls.first[:upscale]
    assert service.calls.first[:make_zip]
  end
end
