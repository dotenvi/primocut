module Pipeline
  # One transcript segment: an index and its real [start, end] in seconds. The
  # index is authoritative — the golden rule of analysis (Cut Room) resolves
  # model-selected indices back to these real times, never the reverse. Ported
  # from the PoC `models.py::Segment`.
  Segment = Data.define(:index, :start, :end, :text)
end
