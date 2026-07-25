module Pipeline
  # An essential stage failed (audio or transcription) — the run aborts with a
  # clear message. Chat and (later) analysis are degradable and never raise this.
  # Ported from the PoC `pipeline.py::PipelineError`. (Own file — Zeitwerk wants
  # one constant per file.)
  class Error < StandardError; end
end
