require "test_helper"

# Tests that the project-level audience-request aggregation reads only the project's
# own comment syntheses and folds their requests, merging spelling variants.
class Competitors::AudienceRequestsTest < ActiveSupport::TestCase
  def synthesise(video, requests)
    video.video_enrichments.create!(
      kind: Competitors::CommentSynthesis::KIND, state: "done", content_hash: "h#{video.id}",
      payload: { "requests" => requests }
    )
  end

  def guest(value, mentions)
    { "type" => "guest", "value" => value, "value_key" => Competitors::CommentSynthesis.request_key(value), "mentions" => mentions }
  end

  test "aggregates the project's syntheses and never leaks a foreign project's" do
    project = Project.create!(name: "Niche")
    channel = CompetitorChannel.create!(youtube_channel_id: "UCc")
    project.project_channels.create!(competitor_channel: channel)
    v1 = channel.competitor_videos.create!(youtube_video_id: "v1", title: "A")
    v2 = channel.competitor_videos.create!(youtube_video_id: "v2", title: "B")
    synthesise(v1, [ guest("Fulano", 3) ])
    synthesise(v2, [ guest("  fulano!  ", 2) ])

    other = Project.create!(name: "Other")
    other_channel = CompetitorChannel.create!(youtube_channel_id: "UCx")
    other.project_channels.create!(competitor_channel: other_channel)
    ox = other_channel.competitor_videos.create!(youtube_video_id: "x1", title: "X")
    synthesise(ox, [ guest("Ninguem", 9) ])

    agg = Competitors::AudienceRequests.new(project).call

    guests = agg["by_type"]["guest"]
    assert_equal 1, guests.size
    assert_equal 2, guests[0]["videos"]   # v1 + v2 merged despite spelling
    assert_equal 5, guests[0]["mentions"]
    assert guests.none? { |g| g["value"] == "Ninguem" } # the foreign project stays out
  end
end
