module Metrics
  # Read-only metrics settings, injected into the metrics services (DIP) with the
  # PoC defaults. Ported from the relevant knobs of the PoC `config.Settings`. Bands
  # are global — never per-project (see Core#band_ruler). Keeping this a plain value
  # object (not Rails.application.config) is deliberate: services take `config:` in
  # their constructor, so a test overrides one knob without touching global state.
  class Config
    attr_reader :outlier_window_videos, :outlier_window_days, :outlier_min_sample,
                :outlier_provisional_days, :band_basis, :band_cutoffs_percentile,
                :band_cutoffs_fixed, :vph_current_window_hours, :resurgence_min_age_days,
                :resurgence_k, :resurgence_baseline_days, :resurgence_min_vph,
                :packaging_impact_window_days, :pattern_confidence

    def initialize(
      outlier_window_videos: 50,
      outlier_window_days: 180,
      outlier_min_sample: 10,
      outlier_provisional_days: 7,
      band_basis: "percentile",
      band_cutoffs_percentile: "90,97,99",
      band_cutoffs_fixed: "3,6,10",
      vph_current_window_hours: 24,
      resurgence_min_age_days: 30,
      resurgence_k: 3.0,
      resurgence_baseline_days: 7,
      resurgence_min_vph: 1.0,
      packaging_impact_window_days: 7,
      pattern_confidence: 1.96
    )
      @outlier_window_videos = outlier_window_videos
      @outlier_window_days = outlier_window_days
      @outlier_min_sample = outlier_min_sample
      @outlier_provisional_days = outlier_provisional_days
      @band_basis = band_basis
      @band_cutoffs_percentile = band_cutoffs_percentile
      @band_cutoffs_fixed = band_cutoffs_fixed
      @vph_current_window_hours = vph_current_window_hours
      @resurgence_min_age_days = resurgence_min_age_days
      @resurgence_k = resurgence_k
      @resurgence_baseline_days = resurgence_baseline_days
      @resurgence_min_vph = resurgence_min_vph
      @packaging_impact_window_days = packaging_impact_window_days
      @pattern_confidence = pattern_confidence
    end

    # The active band basis and its three ordinal cutoffs (global, read-only).
    def band_cutoffs
      spec = band_basis == "percentile" ? band_cutoffs_percentile : band_cutoffs_fixed
      Core.parse_cutoffs(spec)
    end
  end
end
