# The source-videos screen: list the project's submitted videos, accept a new
# submission, re-run a settled one, and serve the list for the polling frame.
class SourcesController < ProjectScopedController
  rescue_from Sources::Submit::Failed, with: :reopen_form
  rescue_from Sources::Rerun::StillRunning, with: :report_failure

  def index
    @sources = screen
  end

  # The list alone, re-fetched by the polling frame while anything is in flight.
  # Renders the partial without a layout so a poll is cheap.
  def show
    render partial: "sources/list", locals: { sources: screen }
  end

  def create
    video = Sources::Submit.new.call(project: @project, url: params.dig(:source_video, :url))
    redirect_to sources, notice: helpers.submitted_notice(video)
  end

  def rerun
    video = Sources::Rerun.new.call(project: @project, id: params[:id])
    redirect_to sources, notice: helpers.rerun_notice(video)
  end

  private

  # The one place the screen's url vocabulary is read. The full page and the
  # polling frame render the same screen, so a third piece of state is added
  # here or nowhere.
  def screen = Sources::Screen.new(@project, opened_id: params[:pipeline], adding: params[:new]).call

  # A rejected link leaves the field open, holding its own error: closing it
  # would make the user re-open it to see what was wrong.
  def reopen_form(error) = redirect_to(sources(new: 1), alert: error.message)

  def report_failure(error) = redirect_to(sources, alert: error.message)

  def sources(**query) = project_sources_path(@project, **query)
end
