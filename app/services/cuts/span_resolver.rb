module Cuts
  # The golden rule of analysis (technical guideline #2): the LLM NEVER invents
  # timestamps — it returns pairs of segment INDICES, and this resolves them back
  # to real seconds from the transcript. Robust against the model: out-of-range
  # indices are clamped and a reversed pair is sorted. Ported from the PoC
  # `models.py::Transcript.resolve_span`.
  class SpanResolver
    def initialize(segments)
      @segments = segments.sort_by { |s| s["index"].to_i }
    end

    # (start_sec, end_sec) for the segment index span [start_index, end_index].
    def resolve(start_index, end_index)
      return [ 0.0, 0.0 ] if @segments.empty?

      lo, hi = [ start_index, end_index ].minmax
      last = @segments.size - 1
      lo = lo.clamp(0, last)
      hi = hi.clamp(0, last)
      [ @segments[lo]["start"].to_f, @segments[hi]["end"].to_f ]
    end
  end
end
