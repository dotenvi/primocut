class NicheController < ProjectScopedController
  def show
    @niche = Niche::Screen.new(@project, tab: params[:tab], fmt: params[:fmt]).call
  end
end
