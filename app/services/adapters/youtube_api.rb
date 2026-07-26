require "json"
require "net/http"
require "time"
require "uri"

module Adapters
  # YouTube Data API v3 client — public data only, with quota accounting.
  #
  # Quota accounting: every call adds its cost (in units) to `units_used`.
  # Batching is exploited where the API allows it — `videos.list` with up to 50
  # IDs costs a single unit. The HTTP transport is injectable
  # (`transport.call(endpoint, params) -> Hash`) so the whole client is testable
  # without network access. Ported from the PoC `youtube/client.py` (plus the
  # reference resolver from `youtube/resolve.py`).
  class YoutubeApi
    API_ROOT = "https://www.googleapis.com/youtube/v3".freeze

    # Quota cost per API operation (YouTube Data API v3), keyed by endpoint.
    # videos.list is 1 unit regardless of how many IDs (up to 50) are requested.
    QUOTA_COSTS = {
      "channels" => 1,
      "playlistItems" => 1,
      "videos" => 1,
      "commentThreads" => 1,
      "search" => 100
    }.freeze

    # The default project budget the API grants per day, and when that day turns
    # over. The API reports NO usage of its own — there is no endpoint to ask, only
    # a 403 `quotaExceeded` once it is too late — so usage is accounted locally
    # from QUOTA_COSTS. That accounting is exact while this key has no other
    # client, and it is only meaningful against Google's day, which starts at
    # midnight Pacific, not at the app's midnight.
    DAILY_QUOTA_UNITS = 10_000
    QUOTA_RESET_ZONE = "America/Los_Angeles".freeze

    # The start of the current quota day, as an absolute time.
    def self.quota_day_start(now = Time.current)
      now.in_time_zone(QUOTA_RESET_ZONE).beginning_of_day.utc
    end

    # A well-known, stable channel used for the cheap liveness/quota probe.
    PROBE_CHANNEL_ID = "UC_x5XG1OV2P6uZZ5FSM9Ttw".freeze # Google Developers

    # A channel ID is "UC" followed by 22 chars of the base64url alphabet.
    CHANNEL_ID_RE = /\AUC[0-9A-Za-z_-]{22}\z/

    ISO_DURATION_RE =
      /\AP(?:(?<days>\d+)D)?T(?:(?<hours>\d+)H)?(?:(?<minutes>\d+)M)?(?:(?<seconds>\d+)S)?\z/

    # A permanent YouTube API error (bad key, not found, quota exceeded). It is
    # non-transient: callers degrade and log, never crash.
    class Error < StandardError; end

    # The uploader turned comments off on this video. A distinct type because it
    # is not a failure to recover from but a permanent fact about the video: the
    # collector records it as a terminal state and stops asking, instead of
    # retrying every cycle forever.
    class CommentsDisabledError < Error; end

    ChannelInfo = Data.define(:channel_id, :title, :handle, :uploads_playlist_id)
    ChannelStats = Data.define(:channel_id, :subscribers, :total_views, :video_count)
    CommentInfo = Data.define(:comment_id, :text, :like_count, :author)
    VideoInfo = Data.define(
      :video_id, :title, :published_at, :duration_s, :thumbnail_url,
      :view_count, :like_count, :comment_count
    )

    attr_reader :units_used

    def initialize(api_key, transport: nil, retry_policy: Resilience::RetryPolicy.new)
      @key = api_key
      @transport = transport || method(:http_transport)
      @retry_policy = retry_policy
      @units_used = 0
    end

    # Build from ENV["YOUTUBE_API_KEY"] (no PRIMOCUT_ prefix, per project convention).
    def self.from_env(env = ENV)
      key = env["YOUTUBE_API_KEY"]
      raise Error, "YOUTUBE_API_KEY is not set." if key.nil? || key.strip.empty?

      new(key)
    end

    # -- operations --

    # Resolve a channel to its id + uploads playlist (1 unit).
    def get_channel(channel_id: nil, handle: nil, username: nil)
      params = { "part" => "snippet,contentDetails" }
      if channel_id
        params["id"] = channel_id
      elsif handle
        params["forHandle"] = handle
      elsif username
        params["forUsername"] = username
      else
        raise ArgumentError, "get_channel needs channel_id, handle or username."
      end

      data = call_api("channels", params, cost: QUOTA_COSTS["channels"])
      items = data["items"] || []
      raise Error, "Channel not found (#{channel_id || handle || username})." if items.empty?

      item = items.first
      snippet = item["snippet"] || {}
      ChannelInfo.new(
        channel_id: item["id"],
        title: snippet["title"] || "",
        handle: snippet["customUrl"] || "",
        uploads_playlist_id: item.dig("contentDetails", "relatedPlaylists", "uploads") || ""
      )
    end

    # Page through the uploads playlist (playlistItems.list, 1 unit/page of 50).
    def list_uploads_video_ids(playlist_id, limit: 120)
      ids = []
      page_token = nil
      while ids.size < limit
        params = {
          "part" => "contentDetails",
          "playlistId" => playlist_id,
          "maxResults" => [ 50, limit - ids.size ].min
        }
        params["pageToken"] = page_token if page_token
        data = call_api("playlistItems", params, cost: QUOTA_COSTS["playlistItems"])
        (data["items"] || []).each do |item|
          vid = item.dig("contentDetails", "videoId")
          ids << vid if vid
        end
        page_token = data["nextPageToken"]
        break unless page_token
      end
      ids.first(limit)
    end

    # Fetch metadata in batches of 50 (videos.list, 1 unit per batch).
    def list_videos(video_ids)
      out = []
      video_ids.each_slice(50) do |chunk|
        data = call_api(
          "videos",
          { "part" => "snippet,contentDetails,statistics", "id" => chunk.join(","), "maxResults" => 50 },
          cost: QUOTA_COSTS["videos"]
        )
        (data["items"] || []).each { |item| out << parse_video(item) }
      end
      out
    end

    # Page the video's most relevant comment threads (1 unit per page of 100).
    #
    # `order=relevance` is YouTube's own top-comment ranking — the same one the
    # watch page shows. Only top-level comments are collected, and `pages` caps
    # the spend: the tail of a long thread adds noise, not signal.
    #
    # Raises CommentsDisabledError when the uploader turned comments off.
    def list_top_comments(video_id, pages: 2)
      out = []
      page_token = nil
      [ pages, 0 ].max.times do
        params = {
          "part" => "snippet",
          "videoId" => video_id,
          "order" => "relevance",
          "maxResults" => 100,
          "textFormat" => "plainText"
        }
        params["pageToken"] = page_token if page_token
        begin
          data = call_api("commentThreads", params, cost: QUOTA_COSTS["commentThreads"])
        rescue Error => e
          # The API signals this as a plain 403; the reason is only in the body,
          # which the transport folds into the message.
          raise CommentsDisabledError, "comments are disabled on video #{video_id}" if e.message.include?("commentsDisabled")

          raise
        end
        (data["items"] || []).each do |item|
          comment = parse_comment_thread(item)
          out << comment if comment
        end
        page_token = data["nextPageToken"]
        break unless page_token
      end
      out
    end

    # Fetch channel statistics in batches of 50 (channels.list, 1 unit/batch).
    def get_channels_stats(channel_ids)
      out = []
      channel_ids.each_slice(50) do |chunk|
        data = call_api(
          "channels",
          { "part" => "statistics", "id" => chunk.join(","), "maxResults" => 50 },
          cost: QUOTA_COSTS["channels"]
        )
        (data["items"] || []).each do |item|
          stats = item["statistics"] || {}
          out << ChannelStats.new(
            channel_id: item["id"],
            subscribers: to_i(stats["subscriberCount"]),
            total_views: to_i(stats["viewCount"]),
            video_count: to_i(stats["videoCount"])
          )
        end
      end
      out
    end

    # Cheap liveness/quota check for the doctor. Returns the units consumed.
    def probe
      before = @units_used
      call_api("channels", { "part" => "id", "id" => PROBE_CHANNEL_ID }, cost: QUOTA_COSTS["channels"])
      @units_used - before
    end

    # -- reference resolution (from PoC youtube/resolve.py) --

    # Return kwargs for `get_channel` (channel_id | handle | username). We avoid
    # `search.list` (100 units): every supported form maps to id/handle/username.
    def self.parse_channel_reference(reference)
      ref = (reference || "").strip
      raise ArgumentError, "Empty channel reference." if ref.empty?
      return { channel_id: ref } if CHANNEL_ID_RE.match?(ref)
      return { handle: ref } if ref.start_with?("@")

      parsed = begin
        URI.parse(ref)
      rescue URI::InvalidURIError
        nil
      end
      if parsed && %w[http https].include?(parsed.scheme)
        parts = parsed.path.split("/").reject(&:empty?)
        raise ArgumentError, "Could not find a channel in the URL: #{reference}" if parts.empty?

        head = parts[0]
        return { channel_id: parts[1] } if head == "channel" && parts[1] && CHANNEL_ID_RE.match?(parts[1])
        return { username: parts[1] } if head == "user" && parts[1]
        return { handle: head } if head.start_with?("@")
        return { handle: as_handle(parts[1]) } if head == "c" && parts[1] # legacy custom URL

        return { handle: as_handle(head) }
      end

      { handle: as_handle(ref) } # bare token: treat as a handle
    end

    def self.as_handle(value)
      value.start_with?("@") ? value : "@#{value}"
    end

    # Convert an ISO-8601 duration (e.g. "PT1H2M3S") to whole seconds.
    def self.parse_iso8601_duration(value)
      return 0 if value.nil? || value.empty?

      m = ISO_DURATION_RE.match(value)
      return 0 unless m

      days = (m[:days] || 0).to_i
      hours = (m[:hours] || 0).to_i
      minutes = (m[:minutes] || 0).to_i
      seconds = (m[:seconds] || 0).to_i
      ((days * 24 + hours) * 60 + minutes) * 60 + seconds
    end

    private

    # One accounted, retried request. Transient failures (429/5xx, network) are
    # retried by the resilience policy; permanent ones propagate immediately.
    def call_api(endpoint, params, cost:)
      result = Resilience.with_retry(policy: @retry_policy, label: "youtube.#{endpoint}") do
        @transport.call(endpoint, params.merge("key" => @key))
      end
      @units_used += cost
      Rails.logger.info("youtube #{endpoint}: +#{cost} unit(s) (cumulative=#{@units_used})")
      result
    end

    # Default transport: a single GET, classifying the response so the retry
    # policy sees transient failures (429/5xx) and callers see permanent ones.
    def http_transport(endpoint, params)
      uri = URI("#{API_ROOT}/#{endpoint}")
      uri.query = URI.encode_www_form(params)
      response = Net::HTTP.get_response(uri)
      return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)

      code = response.code.to_i
      raise Resilience::TransientError, "YouTube #{endpoint} transient HTTP #{code}" if code == 429 || code >= 500

      raise Error, "YouTube #{endpoint} failed: HTTP #{code} #{response.body.to_s[0, 300]}"
    end

    def parse_video(item)
      snippet = item["snippet"] || {}
      content = item["contentDetails"] || {}
      stats = item["statistics"] || {}
      VideoInfo.new(
        video_id: item["id"],
        title: snippet["title"] || "",
        published_at: parse_published_at(snippet["publishedAt"] || ""),
        duration_s: self.class.parse_iso8601_duration(content["duration"] || ""),
        thumbnail_url: best_thumbnail_url(snippet["thumbnails"] || {}),
        view_count: to_i(stats["viewCount"]),
        like_count: to_i(stats["likeCount"]),
        comment_count: to_i(stats["commentCount"])
      )
    end

    # Pull the top-level comment out of a commentThreads item; nil if malformed.
    def parse_comment_thread(item)
      top = item.dig("snippet", "topLevelComment") || {}
      comment_id = top["id"]
      return nil unless comment_id

      snippet = top["snippet"] || {}
      original = snippet["textOriginal"].to_s
      CommentInfo.new(
        comment_id: comment_id,
        text: original.empty? ? (snippet["textDisplay"] || "") : original,
        like_count: to_i(snippet["likeCount"]),
        author: snippet["authorDisplayName"] || ""
      )
    end

    def best_thumbnail_url(thumbnails)
      %w[maxres standard high medium default].each do |key|
        entry = thumbnails[key]
        return entry["url"] if entry && entry["url"]
      end
      ""
    end

    def parse_published_at(value)
      return nil if value.nil? || value.empty?

      Time.iso8601(value)
    rescue ArgumentError
      nil
    end

    # Parse a stringy count from the API; missing/hidden counts become 0.
    def to_i(value)
      Integer(value)
    rescue TypeError, ArgumentError
      0
    end
  end
end
