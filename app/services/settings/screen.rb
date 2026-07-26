module Settings
  # Everything the project's Settings screen renders: the channels you publish to
  # in this niche, and the outlier bands the whole app scores against. PURE READ.
  #
  # The bands are read-only here on purpose — they are a GLOBAL setting applied
  # identically to every project (see Metrics::Core#band_ruler). Showing them
  # per-project without saying so would suggest each niche can be tuned, which
  # would silently make two projects' outliers incomparable.
  class Screen
    Result = Struct.new(:own_channels, :basis, :cutoffs, keyword_init: true) do
      def percentile? = basis == "percentile"
      def cutoff(band) = cutoffs[band]
    end

    BANDS = Metrics::Core::BAND_NAMES

    def initialize(project, config: Metrics::Config.new)
      @project = project
      @config = config
    end

    def call
      Result.new(
        own_channels: @project.own_channels.order(:handle, :id).to_a,
        basis: @config.band_basis,
        cutoffs: @config.band_cutoffs
      )
    end
  end
end
