require "json"
require "pathname"
require "uri"

module Adapters
  # yt-dlp wrapper: metadata (`-J`) and audio download + 16kHz-mono normalization.
  # Ported from the PoC `download/audio.py`. The subprocess seam (`shell`) is
  # injectable, so metadata parsing and the download orchestration (player_client
  # fallback, resume, cleanup) are testable without the real binary or a network.
  class Ytdlp
    # A permanent yt-dlp failure (bad link, extractor broke on every client). The
    # pipeline surfaces this as an essential-stage error.
    class Error < StandardError; end

    Metadata = Data.define(:youtube_id, :url, :title, :channel, :duration_s)

    # YouTube video IDs are exactly 11 characters from this alphabet.
    VIDEO_ID_RE = /\A[A-Za-z0-9_-]{11}\z/
    YOUTUBE_HOSTS = %w[
      youtube.com www.youtube.com m.youtube.com music.youtube.com youtu.be
    ].freeze

    def initialize(
      shell: Shell.new,
      base_cmd: self.class.default_base_cmd,
      ffmpeg_cmd: self.class.default_ffmpeg_cmd,
      player_clients: self.class.default_player_clients,
      retry_policy: Resilience::RetryPolicy.new
    )
      @shell = shell
      @base_cmd = base_cmd
      @ffmpeg_cmd = ffmpeg_cmd
      @player_clients = player_clients
      @retry_policy = retry_policy
    end

    # No PRIMOCUT_ prefix, per project convention. Whitespace-split so an override
    # like "python -m yt_dlp" (the PoC's venv-safe form) still works.
    def self.default_base_cmd
      (ENV["YTDLP_CMD"] || "yt-dlp").split
    end

    def self.default_ffmpeg_cmd
      (ENV["FFMPEG_CMD"] || "ffmpeg").split
    end

    def self.default_player_clients
      (ENV["YTDLP_PLAYER_CLIENTS"] || "").split(",").map(&:strip).reject(&:empty?)
    end

    # -- pure helpers --

    # Extract the video ID from a YouTube URL (watch?v=, youtu.be, /live/, …).
    def self.extract_video_id(url)
      parsed = URI.parse(url.to_s)
      host = parsed.host.to_s
      if host.include?("youtu.be")
        return parsed.path.to_s.delete_prefix("/").split("/").first.to_s
      end

      query = URI.decode_www_form(parsed.query.to_s).to_h
      return query["v"] if query.key?("v")

      parts = parsed.path.to_s.split("/").reject(&:empty?)
      return parts[1] if parts.size > 1 && %w[live embed shorts].include?(parts[0])
      return parts.last if parts.any?

      raise Error, "Could not extract the video ID from: #{url}"
    rescue URI::InvalidURIError
      raise Error, "Could not extract the video ID from: #{url}"
    end

    # The download window [dl_start, dl_end] = the item range widened by `margin_s`,
    # clamped to [0, duration] (an unknown duration <= 0 skips the upper clamp).
    def self.section_bounds(start_s, end_s, margin_s, duration)
      dl_start = [ 0.0, start_s - margin_s ].max
      dl_end = end_s + margin_s
      dl_end = [ duration, dl_end ].min if duration && duration.positive?
      [ dl_start, dl_end ]
    end

    # Validate the link format and return the canonical video URL. Rejects
    # non-YouTube links and malformed URLs (e.g. pasted shell escape backslashes).
    def self.validate_youtube_url(url)
      raw = url.to_s.strip
      raise Error, "Empty URL." if raw.empty?

      parsed = begin
        URI.parse(raw)
      rescue URI::InvalidURIError
        nil
      end
      raise Error, "The URL must start with http:// or https:// — got: #{url.inspect}" unless parsed && %w[http https].include?(parsed.scheme)

      host = parsed.host.to_s.downcase
      raise Error, "Not a YouTube link: #{url.inspect}." unless YOUTUBE_HOSTS.include?(host)

      video_id = begin
        extract_video_id(raw)
      rescue Error
        ""
      end
      unless VIDEO_ID_RE.match?(video_id)
        raise Error,
          "Could not find a valid video ID (11 characters) in: #{url.inspect}. " \
          "Check that the link is a video and has no escape characters (backslashes)."
      end

      "https://www.youtube.com/watch?v=#{video_id}"
    end

    # -- operations --

    # Collect metadata via `yt-dlp -J` (no media download), with transient retry.
    def fetch_metadata(url)
      data = Resilience.with_retry(policy: @retry_policy, label: "ytdlp.metadata") do
        JSON.parse(@shell.capture([ *@base_cmd, "-J", "--no-warnings", url ]))
      end
      Metadata.new(
        youtube_id: data["id"] || self.class.extract_video_id(url),
        url: data["webpage_url"] || url,
        title: data["title"] || "(no title)",
        channel: data["channel"] || data["uploader"] || "(unknown)",
        duration_s: (data["duration"] || 0).to_i
      )
    end

    # Download the audio and normalize it to 16kHz mono WAV. Returns the .wav path.
    #
    # Resilience: transient retry per attempt + yt-dlp player_client fallback (the
    # YouTube extractor breaks frequently). Resume: an existing normalized WAV is
    # reused instead of re-downloading.
    def download_audio(url, out_dir, video_id: nil)
      out_dir = Pathname(out_dir)
      out_dir.mkpath
      vid = video_id || self.class.extract_video_id(url)
      src_template = out_dir.join("#{vid}.src.%(ext)s").to_s
      normalized = out_dir.join("#{vid}.16k.wav")

      return normalized if normalized.exist? && normalized.size.positive?

      download_source(url, src_template)
      src = find_src(out_dir, vid)

      # SINGLE FFmpeg pass: decode + resample to 16kHz mono. `-nostdin` guards
      # against SIGTTIN when running detached in a job work-horse.
      @shell.run([
        *@ffmpeg_cmd, "-nostdin", "-hide_banner", "-loglevel", "error", "-stats", "-y",
        "-i", src.to_s, "-ar", "16000", "-ac", "1", normalized.to_s
      ])
      begin
        src.delete
      rescue SystemCallError
        # the compressed source is disposable — the cache is the .16k.wav
      end
      normalized
    end

    # Download ONLY the section around a cut item and return the produced file path.
    #
    # The section is an EPHEMERAL intermediate: the caller writes it to a throwaway
    # temp dir and discards it when the clip is done. `--force-keyframes-at-cuts`
    # makes the section span EXACTLY [dl_start, dl_end] (its local time 0 = the
    # source time `dl_start`, A/V synced) — without it yt-dlp's keyframe copy + merge
    # mangles YouTube's AV1+Opus timestamps and the downstream trim seeks wrong.
    #
    # Resilience mirrors the audio download: transient retry + a player_client
    # fallback (the YouTube extractor breaks frequently), and yt-dlp's own stderr
    # is surfaced in the raised error so a failure is actionable.
    def download_section(url, out_dir, start_s:, end_s:, margin_s:, duration:)
      out_dir = Pathname(out_dir)
      out_dir.mkpath
      dl_start, dl_end = self.class.section_bounds(start_s, end_s, margin_s, duration)
      out_template = out_dir.join("section.%(ext)s").to_s
      download_section_source(url, out_template, dl_start, dl_end)
      find_section(out_dir)
    end

    private

    def download_section_source(url, out_template, dl_start, dl_end)
      attempts = @player_clients.empty? ? [ [] ] : @player_clients.map { |c| [ "--extractor-args", "youtube:player_client=#{c}" ] }
      last = nil
      succeeded = attempts.any? do |extra|
        Resilience.with_retry(policy: @retry_policy, label: "ytdlp.section") do
          @shell.run(build_section_cmd(url, out_template, dl_start, dl_end, extra))
        end
        true
      rescue StandardError => e
        last = e
        Rails.logger.warn("yt-dlp section download failed (#{extra.empty? ? "default" : extra.last}): #{e.message}")
        false
      end
      return if succeeded

      raise Error,
        "Failed to download the clip section after #{attempts.size} yt-dlp configuration(s). " \
        "Try updating yt-dlp or adjusting YTDLP_PLAYER_CLIENTS. Last error: #{last}"
    end

    # `bv*+ba/b` keeps the original resolution (best video + best audio, merged).
    def build_section_cmd(url, out_template, dl_start, dl_end, extra)
      [
        *@base_cmd, "-f", "bv*+ba/b",
        "--download-sections", format("*%.3f-%.3f", dl_start, dl_end),
        "--force-keyframes-at-cuts", "--merge-output-format", "mkv", "--no-warnings",
        *extra, "-o", out_template, url
      ]
    end

    def find_section(out_dir)
      match = Pathname.glob(out_dir.join("section.*")).find(&:file?)
      raise Error, "yt-dlp did not produce the section file." unless match

      match
    end

    # Try each player_client in turn; the first that downloads wins. yt-dlp only
    # grabs the best compressed audio here (no WAV conversion) — one ffmpeg pass
    # and no multi-GB intermediate.
    def download_source(url, src_template)
      attempts = @player_clients.empty? ? [ [] ] : @player_clients.map { |c| [ "--extractor-args", "youtube:player_client=#{c}" ] }
      last = nil
      succeeded = attempts.any? do |extra|
        Resilience.with_retry(policy: @retry_policy, label: "ytdlp.audio") do
          @shell.run([ *@base_cmd, "-f", "bestaudio/best", "--no-warnings", *extra, "-o", src_template, url ])
        end
        true
      rescue StandardError => e
        last = e
        Rails.logger.warn("yt-dlp download failed (#{extra.empty? ? "default" : extra.last}): #{e.message}")
        false
      end
      return if succeeded

      raise Error,
        "Failed to download the audio after #{attempts.size} yt-dlp configuration(s). " \
        "Try updating yt-dlp or adjusting YTDLP_PLAYER_CLIENTS. Last error: #{last}"
    end

    def find_src(out_dir, vid)
      match = Pathname.glob(out_dir.join("#{vid}.src.*")).find(&:file?)
      raise Error, "yt-dlp did not produce the audio file for #{vid}." unless match

      match
    end
  end
end
