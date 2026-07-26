class AnalysesController < ProjectScopedController
  rescue_from Competitors::VideoAnalysis::UnknownKind, with: :not_found

  # The priced button, loaded lazily: computing the price means scoring the
  # project, which the tab must not wait on.
  def show
    plan = Competitors::AnalysisPlan.new(@project, kind: params[:kind]).call
    render partial: "analyses/button", locals: { plan: plan }
  end

  def create
    plan = Competitors::AnalyzeProject.new.call(project: @project, kind: params[:kind])
    redirect_to project_niche_path(@project), notice: helpers.analysis_notice(plan)
  end

  private

  def not_found = head(:not_found)
end
