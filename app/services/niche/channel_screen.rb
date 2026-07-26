module Niche
  # Everything one competitor channel's dashboard renders. PURE READ.
  #
  # The leakage guard lives here, at the read itself: the channel must be tracked
  # by THIS project or it does not exist, so a channel reached through another
  # project's url is a 404 rather than a cross-project peek.
  class ChannelScreen
    Result = Struct.new(:channel, :dashboard, :fmt, keyword_init: true) do
      def outliers = dashboard[:outliers][fmt]
      def count(format) = dashboard[:outliers][format].length
    end

    def initialize(project, channel_id:, fmt: nil)
      @project = project
      @channel_id = channel_id
      @fmt = Screen::FORMATS.include?(fmt) ? fmt : Screen::FORMATS.first
    end

    def call
      channel = @project.competitor_channels.find_by!(youtube_channel_id: @channel_id)
      Result.new(channel: channel, fmt: @fmt, dashboard: Metrics::ChannelDashboard.new(channel).call)
    end
  end
end
