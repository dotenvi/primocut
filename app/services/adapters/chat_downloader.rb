require "json"
require "pathname"
require "tmpdir"

module Adapters
  # Live-chat replay download. OPTIONAL signal — never blocks the pipeline.
  # Ported from the PoC `chat/downloader.py`. Fallback strategy:
  #   1. the `chat_downloader` CLI (primary);
  #   2. yt-dlp `--live-chat` (parses the `.live_chat.json` subtitle track);
  #   3. both fail → nil (the pipeline continues without chat).
  #
  # The two fetchers are injectable so parsing and the fallback ladder are
  # testable without a network or the real binaries.
  class ChatDownloader
    Message = Data.define(:offset_seconds, :author, :text)

    def initialize(
      shell: Shell.new,
      chat_json_fetcher: nil,
      live_chat_lines_fetcher: nil,
      chat_cmd: self.class.default_chat_cmd,
      ytdlp_base_cmd: Ytdlp.default_base_cmd
    )
      @shell = shell
      @chat_cmd = chat_cmd
      @ytdlp_base_cmd = ytdlp_base_cmd
      @chat_json_fetcher = chat_json_fetcher || method(:default_chat_json)
      @live_chat_lines_fetcher = live_chat_lines_fetcher || method(:default_live_chat_lines)
    end

    def self.default_chat_cmd
      (ENV["CHAT_DOWNLOADER_CMD"] || "chat_downloader").split
    end

    # Replay messages (chat_downloader → yt-dlp fallback), or nil.
    def download(url)
      messages = via_chat_downloader(url)
      if messages&.any?
        Rails.logger.info("Chat: #{messages.size} messages (chat_downloader).")
        return messages
      end

      messages = via_ytdlp_live_chat(url)
      if messages&.any?
        Rails.logger.info("Chat: #{messages.size} messages (yt-dlp fallback).")
        return messages
      end

      Rails.logger.info("No usable chat replay.")
      nil
    end

    private

    def via_chat_downloader(url)
      items = @chat_json_fetcher.call(url)
      messages = Array(items).filter_map do |item|
        secs = item["time_in_seconds"]
        next if secs.nil? # messages off the timeline (e.g. super chats without offset)

        author = item["author"]
        name = author.is_a?(Hash) ? author["name"].to_s : author.to_s
        Message.new(offset_seconds: secs.to_f, author: name, text: item["message"].to_s)
      end
      messages.empty? ? nil : messages
    rescue StandardError => e # missing replay / network / parsing
      Rails.logger.warn("chat_downloader failed: #{e.message}")
      nil
    end

    def via_ytdlp_live_chat(url)
      lines = @live_chat_lines_fetcher.call(url)
      messages = Array(lines).filter_map do |line|
        line = line.to_s.strip
        next if line.empty?

        obj = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        parse_live_chat_line(obj)
      end
      messages.empty? ? nil : messages
    rescue StandardError => e
      Rails.logger.warn("yt-dlp --live-chat fallback failed: #{e.message}")
      nil
    end

    def parse_live_chat_line(obj)
      action = obj["replayChatItemAction"] || {}
      offset = action["videoOffsetTimeMsec"]
      return nil if offset.nil?

      Array(action["actions"]).each do |a|
        item = (a["addChatItemAction"] || {})["item"] || {}
        renderer = item["liveChatTextMessageRenderer"]
        next unless renderer

        runs = (renderer["message"] || {})["runs"] || []
        text = runs.map { |r| r["text"].to_s }.join
        author = (renderer["authorName"] || {})["simpleText"].to_s
        return Message.new(offset_seconds: offset.to_f / 1000.0, author: author, text: text)
      end
      nil
    end

    # -- default fetchers (shell out) --

    def default_chat_json(url)
      Dir.mktmpdir("primocut-chat-") do |tmp|
        out = File.join(tmp, "chat.json")
        @shell.run([ *@chat_cmd, url, "--output", out, "--message_types", "text" ])
        File.exist?(out) ? JSON.parse(File.read(out)) : []
      end
    end

    def default_live_chat_lines(url)
      Dir.mktmpdir("primocut-livechat-") do |tmp|
        template = File.join(tmp, "chat.%(ext)s")
        @shell.run([
          *@ytdlp_base_cmd, "--skip-download", "--write-subs", "--sub-langs", "live_chat",
          "--no-warnings", "-o", template, url
        ])
        file = Pathname.glob(File.join(tmp, "*.live_chat.json")).first
        file ? file.read.lines : []
      end
    end
  end
end
