class OwnChannelsController < ProjectScopedController
  def create
    channel = Settings::AddOwnChannel.new.call(project: @project, attributes: own_channel_params)
    redirect_to settings, flash: helpers.own_channel_added(channel)
  end

  def destroy
    channel = Settings::RemoveOwnChannel.new.call(project: @project, id: params[:id])
    redirect_to settings, flash: helpers.own_channel_removed(channel)
  end

  private

  def own_channel_params = params.expect(own_channel: [ :channel_url, :handle, :role ])

  def settings = project_settings_path(@project)
end
