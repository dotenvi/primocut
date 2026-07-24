class VideosController < ProjectScopedController
  def show
    # Two-level leakage guard: the channel must belong to this project, and the
    # video to that channel — a video reached through another project's URL is a 404.
    @channel = @project.competitor_channels.find_by!(youtube_channel_id: params[:channel_id])
    @video = @channel.competitor_videos.find_by!(youtube_video_id: params[:video_id])
    @report = Metrics::VideoReport.new(@video).call
    @distribution = Metrics::ChannelDistribution.new(@channel, fmt: @video.is_short ? "short" : "long").call
  end
end
