module Niche
  # Everything the Niche screen renders for the requested tab. PURE READ.
  #
  # Which payload gets built is the decision with weight here, which is why it is
  # one object and not a branch in an action: the channels tab re-fetches itself
  # every couple of seconds while a backfill runs, and the scored dashboard costs
  # ~190ms over a few hundred videos. The two tabs must never share a payload.
  class Screen
    TABS = %w[patterns outliers channels].freeze
    FORMATS = %w[long short].freeze

    Result = Struct.new(:tab, :fmt, :dashboard, :channels, keyword_init: true) do
      def channels? = tab == "channels"
      def rows(key) = dashboard.fetch(key).fetch(fmt)
      def count(key, format) = dashboard.fetch(key).fetch(format).length
    end

    def initialize(project, tab: nil, fmt: nil)
      @project = project
      @tab = TABS.include?(tab) ? tab : TABS.first
      @fmt = FORMATS.include?(fmt) ? fmt : FORMATS.first
    end

    def call
      return Result.new(tab: @tab, fmt: @fmt, channels: channels) if @tab == "channels"

      Result.new(tab: @tab, fmt: @fmt, dashboard: Metrics::NicheDashboard.new(@project).call)
    end

    private

    def channels = Competitors::ChannelList.new(@project).call
  end
end
