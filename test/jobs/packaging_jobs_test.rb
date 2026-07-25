require "test_helper"

# The four thin packaging jobs each load their record and delegate to the service.
class PackagingJobsTest < ActiveSupport::TestCase
  class FakeService
    attr_reader :calls

    def initialize = (@calls = [])

    def generate(cut, kind:, item_ids:, regenerate:) = (@calls << [ :generate, cut, kind ])
    def extract_frames(cut, item_ids:, regenerate:) = (@calls << [ :extract, cut ])
    def rank_frames(cut, item_ids:) = (@calls << [ :rank, cut ])
    def match_audience(source_video, regenerate:) = (@calls << [ :audience, source_video ])
  end

  def setup
    project = Project.create!(name: "Niche")
    @video = project.source_videos.create!(youtube_id: "abcdefghijk", url: "https://y/1")
    @cut = @video.cuts.create!
  end

  test "CutPackagingJob delegates generate with the kind" do
    s = FakeService.new
    CutPackagingJob.perform_now(@cut.id, kind: "title", service: s)
    assert_equal [ [ :generate, @cut, "title" ] ], s.calls
  end

  test "ExtractCutFramesJob delegates extract_frames" do
    s = FakeService.new
    ExtractCutFramesJob.perform_now(@cut.id, service: s)
    assert_equal [ [ :extract, @cut ] ], s.calls
  end

  test "RankCutFramesJob delegates rank_frames" do
    s = FakeService.new
    RankCutFramesJob.perform_now(@cut.id, service: s)
    assert_equal [ [ :rank, @cut ] ], s.calls
  end

  test "MatchAudienceJob delegates match_audience" do
    s = FakeService.new
    MatchAudienceJob.perform_now(@video.id, service: s)
    assert_equal [ [ :audience, @video ] ], s.calls
  end
end
