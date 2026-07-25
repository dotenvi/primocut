module Cuts
  # SubRip (.srt) subtitles for a clip, cut from the source video's transcript
  # segments. Pure. Ported from the PoC `render/package.py::srt_for_clip`.
  module Srt
    module_function

    # Build the SRT for a clip from the transcript `segments` (each a hash with
    # "start"/"end"/"text"). Each overlapping segment is shifted by the clip's start
    # (so the clip's own time base begins at 0) and clamped to [0, clip length].
    # Returns "" when nothing overlaps (a valid, empty .srt).
    def for_clip(segments, clip_start, clip_end)
      duration = [ 0.0, clip_end - clip_start ].max
      blocks = []
      idx = 1
      segments.each do |seg|
        s = seg["start"].to_f
        e = seg["end"].to_f
        text = seg["text"].to_s.strip
        next if e <= clip_start || s >= clip_end || text.empty?

        ns = [ 0.0, s - clip_start ].max
        ne = [ duration, e - clip_start ].min
        next if ne <= ns

        blocks << "#{idx}\n#{ts(ns)} --> #{ts(ne)}\n#{text}"
        idx += 1
      end
      blocks.empty? ? "" : blocks.join("\n\n") + "\n"
    end

    # `HH:MM:SS,mmm` — the SubRip timestamp (comma before the milliseconds).
    def ts(seconds)
      ms = (([ 0.0, seconds ].max) * 1000).round
      h, ms = ms.divmod(3_600_000)
      m, ms = ms.divmod(60_000)
      s, ms = ms.divmod(1_000)
      format("%02d:%02d:%02d,%03d", h, m, s, ms)
    end
  end
end
