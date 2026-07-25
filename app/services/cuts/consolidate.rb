module Cuts
  # Consolidation of spans across overlapping windows. Neighbouring windows share
  # segments (the overlap), so the same topic can show up twice with nearly
  # identical spans. Only items that overlap SUBSTANTIALLY are merged — a distinct
  # subject that merely touches its neighbour at a window boundary is kept
  # separate. Ported from the PoC `analysis/consolidate.py`.
  module Consolidate
    # Minimum temporal overlap, as a fraction of the shorter item's span, for two
    # items to be treated as the same subject. Window duplicates overlap almost
    # entirely (~1.0); distinct adjacent subjects barely overlap, so 0.5 separates
    # the two cases cleanly.
    DEFAULT_MIN_OVERLAP_RATIO = 0.5

    module_function

    # Merge items (responding to .start_s/.end_s/.score and Data#with) that overlap
    # substantially: the merged item keeps the higher-scoring one's metadata and
    # spans the union. Returns the consolidated list in chronological order.
    def merge_overlapping(items, min_overlap_ratio: DEFAULT_MIN_OVERLAP_RATIO)
      return [] if items.empty?

      ordered = items.sort_by { |x| [ x.start_s, x.end_s ] }
      merged = [ ordered.first ]
      ordered.drop(1).each do |it|
        prev = merged.last
        overlap = [ prev.end_s, it.end_s ].min - [ prev.start_s, it.start_s ].max
        shorter = [ prev.end_s - prev.start_s, it.end_s - it.start_s ].min
        if overlap.positive? && (shorter <= 0 || overlap.fdiv(shorter) >= min_overlap_ratio)
          winner = it.score > prev.score ? it : prev
          merged[-1] = winner.with(start_s: [ prev.start_s, it.start_s ].min, end_s: [ prev.end_s, it.end_s ].max)
        else
          merged << it
        end
      end
      merged
    end
  end
end
