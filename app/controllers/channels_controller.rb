class ChannelsController < ProjectScopedController
  rescue_from Competitors::TrackChannel::Failed, with: :report_failure

  def show
    @screen = Niche::ChannelScreen.new(@project, channel_id: params[:channel_id], fmt: params[:fmt]).call
  end

  # The tracked-channel list alone, re-fetched by the polling frame while a
  # backfill is in flight. Renders the partial without a layout so a poll is cheap.
  def index
    render partial: "channels/list", locals: { rows: Competitors::ChannelList.new(@project).call }
  end

  def create
    result = Competitors::TrackChannel.new.call(project: @project, reference: params[:reference])
    redirect_to channels_tab, notice: helpers.tracking_notice(result)
  end

  def destroy
    result = Competitors::UntrackChannel.new.call(project: @project, youtube_channel_id: params[:channel_id])
    redirect_to channels_tab, notice: helpers.untracking_notice(result)
  end

  private

  def report_failure(error) = redirect_to(channels_tab, alert: error.message)

  def channels_tab = project_niche_path(@project, tab: "channels")
end
