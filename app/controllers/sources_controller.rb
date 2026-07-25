# The source-videos screen: list the project's submitted videos, accept a new
# submission, and serve one row's live progress for the polling frame. Scoped to
# @project (ProjectScopedController) — the per-project leakage guard: a video from
# another project is a 404, never rendered here.
class SourcesController < ProjectScopedController
  def index
    @source_videos = @project.source_videos.order(created_at: :desc)
    @source_video = SourceVideo.new
  end

  def create
    url = Adapters::Ytdlp.validate_youtube_url(params.dig(:source_video, :url))
    youtube_id = Adapters::Ytdlp.extract_video_id(url)

    @source_video = @project.source_videos.find_or_initialize_by(youtube_id: youtube_id)
    @source_video.assign_attributes(url: url, status: "queued")
    @source_video.save!

    SourceVideoPipelineJob.perform_later(@source_video.id)
    redirect_to project_sources_path(@project), notice: "Submitted for processing."
  rescue Adapters::Ytdlp::Error, ActiveRecord::RecordInvalid => e
    @source_videos = @project.source_videos.order(created_at: :desc)
    @source_video = SourceVideo.new
    flash.now[:alert] = e.message
    render :index, status: :unprocessable_entity
  end

  # One row, re-fetched by the polling frame while the video is in flight. Renders
  # the partial alone (no layout) so a poll is cheap.
  def show
    source_video = @project.source_videos.find(params[:id])
    render partial: "source_video", locals: { source_video: source_video }
  end
end
