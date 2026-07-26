class SettingsController < ProjectScopedController
  def show
    @settings = Settings::Screen.new(@project).call
  end
end
