class NicheController < ProjectScopedController
  TABS = %w[patterns outliers channels].freeze
  FORMATS = %w[long short].freeze

  def show
    @dashboard = Metrics::NicheDashboard.new(@project).call
    @tab = TABS.include?(params[:tab]) ? params[:tab] : "patterns"
    @fmt = FORMATS.include?(params[:fmt]) ? params[:fmt] : "long"
  end
end
