require "test_helper"

class AnalyzeTopicsJobTest < ActiveSupport::TestCase
  class FakeService
    attr_reader :calls

    def initialize = (@calls = [])
    def call(source_video) = (@calls << source_video)
  end

  test "loads the source video and delegates to the selection service" do
    project = Project.create!(name: "Niche")
    video = project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    service = FakeService.new

    AnalyzeTopicsJob.perform_now(video.id, service:)

    assert_equal [ video ], service.calls
  end
end
