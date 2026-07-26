module SettingsHelper
  # band → the label and the heat colour it is scored in, in ascending order.
  BAND_ROWS = [
    [ "relevant", "Relevant", "text-heat-90" ],
    [ "strong", "Strong", "text-heat-97" ],
    [ "exceptional", "Exceptional", "text-heat-99" ]
  ].freeze

  # A cutoff reads as the basis it is measured in: a percentile rank ("p90") or a
  # multiple of the channel's median ("3×"). Whole numbers lose the decimal —
  # "p90.0" would suggest a precision the cutoff does not have.
  def band_cutoff_label(settings, band)
    value = settings.cutoff(band)
    return "—" if value.nil?

    number = (value % 1).zero? ? value.to_i : value
    settings.percentile? ? "p#{number}" : "#{number}×"
  end

  # Why the numbers mean what they mean — the two bases behave differently enough
  # that the reading changes.
  def band_basis_note(settings)
    if settings.percentile?
      "Percentile recalibrates per channel and per format, so roughly a tenth of " \
        "each channel's videos land in the tail whatever its size."
    else
      "Fixed multiples of the channel's median (legacy basis) — a big channel and a " \
        "small one are held to the same ratio."
    end
  end
end
