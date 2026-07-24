class ChannelsController < ProjectScopedController
  FORMATS = %w[long short].freeze

  def show
    # Leakage guard: the channel must be tracked by THIS project, or it is a 404 —
    # the per-project scoping the PoC enforces at the request boundary.
    @channel = @project.competitor_channels.find_by!(youtube_channel_id: params[:channel_id])
    @dashboard = Metrics::ChannelDashboard.new(@channel).call
    @fmt = FORMATS.include?(params[:fmt]) ? params[:fmt] : "long"
  end
end
