module Cuts
  # Windowing of long transcripts with overlap (technical guideline #3). A 3-4h
  # source video exceeds the LLM's useful context, so the segments are partitioned
  # into windows by target duration, with overlap, keeping the GLOBAL segment
  # indices — essential for the LLM to select spans and for consolidation. Ported
  # from the PoC `analysis/windowing.py`. Segments are the transcript's jsonb hashes.
  module Windowing
    Window = Data.define(:start_index, :end_index, :segments) do
      # The LLM's input: `[i] M:SS text`, one segment per line.
      def indexed_text
        segments.map { |s| "[#{s['index']}] #{Manifest.format_timestamp(s['start'])} #{s['text']}" }.join("\n")
      end
    end

    module_function

    # Split the segments into windows [t, t+target) sliding by (target - overlap).
    def make(segments, target_seconds:, overlap_seconds:)
      return [] if segments.empty?

      duration = segments.last["end"].to_f
      step = [ target_seconds - overlap_seconds, 1.0 ].max
      windows = []
      win_start = 0.0
      while win_start < duration
        win_end = win_start + target_seconds
        chunk = segments.select { |s| win_start <= s["start"].to_f && s["start"].to_f < win_end }
        windows << Window.new(start_index: chunk.first["index"], end_index: chunk.last["index"], segments: chunk) if chunk.any?
        break if win_end >= duration

        win_start += step
      end
      windows
    end
  end
end
