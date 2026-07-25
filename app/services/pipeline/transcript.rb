module Pipeline
  # A transcript as the pipeline passes it around: the engine produces it, the
  # store persists it. A value object, not the ActiveRecord row. Ported from the
  # PoC `models.py::Transcript` (the index→time `resolve_span` lives in the Cut
  # Room's SpanResolver, not here).
  Transcript = Data.define(:youtube_id, :language, :model, :segments) do
    # Wall-clock length, taken from the last segment — used to fill a source
    # video whose metadata came back degraded (duration 0).
    def duration
      segments.empty? ? 0.0 : segments.last.end
    end
  end
end
