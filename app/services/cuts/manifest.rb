require "json"

module Cuts
  # The export manifests: the machine-readable `manifest.json` payload and the
  # human-readable `manifest.md` with clickable timestamps back into the source
  # video. Pure. Ported from the PoC `render/package.py` manifest helpers.
  module Manifest
    module_function

    # The manifest payload: source-video metadata, the cut, the ordered items with
    # their FINAL timestamps, and the master info. `items` is an array of hashes
    # already shaped by the export (position, mp4, srt, title, kind, bounds,
    # packaging). `video` responds to youtube_id/url/title/channel/duration_s.
    def data(video:, cut:, items:, master:, generated_at:)
      {
        "generated_at" => generated_at,
        "live" => {
          "video_id" => video.youtube_id,
          "url" => video.url,
          "title" => video.title,
          "channel" => video.channel,
          "duration_s" => video.duration_s.to_f
        },
        "cut" => { "id" => cut.id, "name" => cut.name },
        "master" => master,
        "items" => items
      }
    end

    def to_json_text(data)
      JSON.pretty_generate(data) + "\n"
    end

    # A human-readable manifest with clickable timestamps into the source video.
    def to_markdown(data)
      live = data["live"]
      cut = data["cut"]
      lines = []
      lines << "# #{live['title'].presence || live['video_id']} — #{cut['name']}"
      lines << ""
      lines << "- **Source**: [#{live['url']}](#{live['url']})"
      lines << "- **Channel**: #{live['channel']}" if live["channel"].present?
      lines << "- **Exported**: #{data['generated_at']}"
      lines << master_line(data["master"])
      lines << ""
      lines << "| # | Clip | Title | Start | End | Duration |"
      lines << "|---|------|-------|-------|-----|----------|"
      data["items"].each { |it| lines << item_row(it, live["video_id"]) }
      packaging_section(lines, data["items"])
      lines << ""
      lines.join("\n")
    end

    # Format seconds as H:MM:SS or M:SS (the PoC `models.format_timestamp`).
    def format_timestamp(seconds)
      total = seconds.to_i
      h, rem = total.divmod(3600)
      m, s = rem.divmod(60)
      h.positive? ? format("%d:%02d:%02d", h, m, s) : format("%d:%02d", m, s)
    end

    def master_line(master)
      return "- **Master**: skipped" unless master

      "- **Master**: `#{master['filename']}` (#{master['resolution'] || 'original'})"
    end

    def item_row(it, video_id)
      title = (it["title"] || "").gsub("|", "\\|")
      watch = watch_url(video_id, it["start_s"])
      "| #{it['position']} | `#{it['mp4']}` | [#{title}](#{watch}) | " \
        "#{format_timestamp(it['start_s'])} | #{format_timestamp(it['end_s'])} | " \
        "#{format_timestamp(it['duration_s'])} |"
    end

    def packaging_section(lines, items)
      packaged = items.select do |it|
        pk = it["packaging"] || {}
        pk["titles"].present? || pk["thumbnail_brief"].present?
      end
      return if packaged.empty?

      lines << ""
      lines << "## Packaging"
      packaged.each do |it|
        pk = it["packaging"]
        lines << ""
        lines << "### #{it['position']}. #{it['title']}"
        (pk["titles"] || []).each { |t| lines << "- #{t}" }
        lines << "- **Thumbnail**: #{pk['thumbnail_brief']}" if pk["thumbnail_brief"].present?
      end
    end

    def watch_url(video_id, start_s)
      "https://www.youtube.com/watch?v=#{video_id}&t=#{start_s.to_i}"
    end
  end
end
