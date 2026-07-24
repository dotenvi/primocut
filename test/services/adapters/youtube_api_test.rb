require "test_helper"

# Tests for the YouTube Data API v3 client — fully faked transport (no network).
# Covers channel resolution, batched video fetching and, above all, quota
# accounting (units consumed per operation). Ported from the PoC
# `tests/test_youtube_client.py`.
class Adapters::YoutubeApiTest < ActiveSupport::TestCase
  Api = Adapters::YoutubeApi

  # Records calls and returns canned JSON per endpoint (a list is drained one
  # entry per call; a bare Hash is returned every time).
  class FakeTransport
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def call(endpoint, params)
      @calls << [ endpoint, params ]
      resp = @responses.fetch(endpoint)
      resp.is_a?(Array) ? resp.shift : resp
    end
  end

  def channels_payload(channel_id: "UCabcdefghijklmnopqrstuv", uploads: "UUxyz")
    {
      "items" => [
        {
          "id" => channel_id,
          "snippet" => { "title" => "Cool Channel", "customUrl" => "@cool" },
          "contentDetails" => { "relatedPlaylists" => { "uploads" => uploads } }
        }
      ]
    }
  end

  def video_item(vid, seconds: "PT3M20S")
    {
      "id" => vid,
      "snippet" => {
        "title" => "Video #{vid}",
        "publishedAt" => "2026-01-02T03:04:05Z",
        "thumbnails" => {
          "high" => { "url" => "https://i.ytimg.com/vi/#{vid}/hq.jpg" },
          "maxres" => { "url" => "https://i.ytimg.com/vi/#{vid}/maxres.jpg" }
        }
      },
      "contentDetails" => { "duration" => seconds },
      "statistics" => { "viewCount" => "1000", "likeCount" => "50", "commentCount" => "7" }
    }
  end

  # ------------------------- reference resolution -------------------------

  test "parse channel reference" do
    assert_equal({ channel_id: "UCabcdefghijklmnopqrstuv" }, Api.parse_channel_reference("UCabcdefghijklmnopqrstuv"))
    assert_equal({ handle: "@handleName" }, Api.parse_channel_reference("@handleName"))
    assert_equal({ handle: "@someChannel" }, Api.parse_channel_reference("https://www.youtube.com/@someChannel"))
    assert_equal({ channel_id: "UCabcdefghijklmnopqrstuv" }, Api.parse_channel_reference("https://youtube.com/channel/UCabcdefghijklmnopqrstuv"))
    assert_equal({ username: "LegacyName" }, Api.parse_channel_reference("https://www.youtube.com/user/LegacyName"))
  end

  test "get channel by id costs one unit" do
    transport = FakeTransport.new("channels" => channels_payload)
    client = Api.new("KEY", transport:)
    info = client.get_channel(channel_id: "UCabcdefghijklmnopqrstuv")

    assert_equal "UCabcdefghijklmnopqrstuv", info.channel_id
    assert_equal "UUxyz", info.uploads_playlist_id
    assert_equal "@cool", info.handle
    assert_equal 1, client.units_used
    # The API key is injected into every request.
    assert_equal "KEY", transport.calls[0][1]["key"]
  end

  test "get channel not found raises" do
    transport = FakeTransport.new("channels" => { "items" => [] })
    client = Api.new("KEY", transport:)
    assert_raises(Api::Error) { client.get_channel(handle: "@nobody") }
  end

  # ------------------------- duration parsing -------------------------

  test "parse iso8601 duration" do
    assert_equal 30, Api.parse_iso8601_duration("PT30S")
    assert_equal 60, Api.parse_iso8601_duration("PT1M")
    assert_equal 200, Api.parse_iso8601_duration("PT3M20S")
    assert_equal 3723, Api.parse_iso8601_duration("PT1H2M3S")
    assert_equal 0, Api.parse_iso8601_duration("P0D")
  end

  # ------------------------- batched video fetch + quota -------------------------

  test "list videos batches 50 ids as one unit each" do
    # 60 ids → 2 batches → 2 units.
    ids = (0...60).map { |i| format("vid%02d", i) }
    batch1 = { "items" => ids[0...50].map { |v| video_item(v) } }
    batch2 = { "items" => ids[50..].map { |v| video_item(v) } }
    transport = FakeTransport.new("videos" => [ batch1, batch2 ])
    client = Api.new("KEY", transport:)

    videos = client.list_videos(ids)

    assert_equal 60, videos.size
    assert_equal 2, client.units_used # 1 unit per batch of 50, not per id
    assert_equal 50, transport.calls[0][1]["id"].split(",").size
    assert_equal 10, transport.calls[1][1]["id"].split(",").size
  end

  test "list videos parses statistics" do
    transport = FakeTransport.new("videos" => { "items" => [ video_item("v1") ] })
    client = Api.new("KEY", transport:)
    v = client.list_videos([ "v1" ]).first
    assert_equal [ 1000, 50, 7 ], [ v.view_count, v.like_count, v.comment_count ]
    assert_includes transport.calls[0][1]["part"], "statistics"
  end

  test "get channels stats batches and parses" do
    payload = {
      "items" => [
        {
          "id" => "UCa",
          "statistics" => { "subscriberCount" => "1200", "viewCount" => "999999", "videoCount" => "42" }
        }
      ]
    }
    transport = FakeTransport.new("channels" => payload)
    client = Api.new("KEY", transport:)
    stats = client.get_channels_stats([ "UCa" ])
    assert_equal 1, client.units_used # 1 unit per batch of up to 50
    assert_equal 1200, stats[0].subscribers
    assert_equal 999999, stats[0].total_views
    assert_equal 42, stats[0].video_count
  end

  test "hidden like count becomes zero" do
    item = video_item("v1")
    item["statistics"].delete("likeCount") # likes can be hidden by the uploader
    transport = FakeTransport.new("videos" => { "items" => [ item ] })
    client = Api.new("KEY", transport:)
    assert_equal 0, client.list_videos([ "v1" ]).first.like_count
  end

  test "list uploads pages until limit" do
    page1 = {
      "items" => (0...50).map { |i| { "contentDetails" => { "videoId" => "a#{i}" } } },
      "nextPageToken" => "tok"
    }
    page2 = { "items" => (0...50).map { |i| { "contentDetails" => { "videoId" => "b#{i}" } } } }
    transport = FakeTransport.new("playlistItems" => [ page1, page2 ])
    client = Api.new("KEY", transport:)

    ids = client.list_uploads_video_ids("UUxyz", limit: 70)

    assert_equal 70, ids.size
    assert_equal 2, client.units_used # 2 pages
  end

  test "top comments raise CommentsDisabledError when comments are off" do
    # The API signals this as a plain 403 whose body carries `commentsDisabled`.
    transport = Object.new
    def transport.calls = @calls ||= []
    def transport.call(endpoint, params)
      calls << [ endpoint, params ]
      raise Adapters::YoutubeApi::Error, "YouTube commentThreads failed: HTTP 403 commentsDisabled"
    end
    client = Api.new("KEY", transport:)
    assert_raises(Api::CommentsDisabledError) { client.list_top_comments("v1") }
  end

  test "probe returns units consumed" do
    transport = FakeTransport.new("channels" => channels_payload)
    client = Api.new("KEY", transport:)
    assert_equal 1, client.probe
    assert_equal 1, client.units_used
  end

  test "from_env requires the key" do
    assert_raises(Api::Error) { Api.from_env({ "YOUTUBE_API_KEY" => nil }) }
    assert_raises(Api::Error) { Api.from_env({ "YOUTUBE_API_KEY" => "  " }) }
    client = Api.from_env({ "YOUTUBE_API_KEY" => "K" })
    assert_instance_of Api, client
  end
end
