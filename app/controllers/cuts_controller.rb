# The Cut Room, per source video — the working screen where a processed video's
# topics are triaged and composed into cuts. Scoped to @project (the leakage guard:
# a source video from another project is a 404). Built section by section; this
# first section is topics + triage.
class CutsController < ProjectScopedController
  before_action :set_source_video

  def show
    load_topics
  end

  # The topics frame alone (no layout), re-fetched by the polling controller while
  # the analysis runs so the topics appear live when the pass finishes.
  def topics
    load_topics
    render partial: "topics"
  end

  # Regenerate the source video's topics with the LLM (background). The video is
  # flipped to "analyzing" so the frame polls until the pass restores it to "done".
  def analyze_topics
    @source_video.update!(status: "analyzing")
    AnalyzeTopicsJob.perform_later(@source_video.id)
    redirect_to project_cut_room_path(@project, @source_video), notice: "Analyzing the transcript for topics…"
  end

  # Record the user's opinion about a topic: "maybe", "discarded" or "open" (clear).
  def triage
    topic = @source_video.topics.find(params[:topic_id])
    Cuts::Triage.set(@source_video, topic, params[:state])
    redirect_to project_cut_room_path(@project, @source_video)
  end

  private

  def set_source_video
    @source_video = @project.source_videos.find(params[:source_video_id])
  end

  def load_topics
    @topics = @source_video.topics.ordered
    @triage = @source_video.topic_triages.index_by(&:topic_id)
  end
end
