require "test_helper"

class CutRenderJobTest < ActiveSupport::TestCase
  class FakeService
    attr_reader :calls

    def initialize = (@calls = [])

    def call(cut, item_ids:, regenerate:, fast_copy:)
      @calls << { cut:, item_ids:, regenerate:, fast_copy: }
      Cuts::Render::Result.new(cut:, rendered: 0, skipped: 0, failed: 0)
    end
  end

  test "loads the cut and delegates to the render service" do
    project = Project.create!(name: "Niche")
    video = project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    cut = video.cuts.create!
    service = FakeService.new

    CutRenderJob.perform_now(cut.id, item_ids: [ 1, 2 ], regenerate: true, service:)

    assert_equal 1, service.calls.size
    assert_equal cut, service.calls.first[:cut]
    assert_equal [ 1, 2 ], service.calls.first[:item_ids]
    assert service.calls.first[:regenerate]
  end

  test "settles the cut back to rendered when it owned the rendering state" do
    project = Project.create!(name: "Niche")
    video = project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    cut = video.cuts.create!(status: "rendering")

    CutRenderJob.perform_now(cut.id, service: FakeService.new)

    assert cut.reload.status_rendered?
  end
end
