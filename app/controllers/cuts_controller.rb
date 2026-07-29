# The Cut Room, per source video — the working screen where a processed video's
# topics are triaged and composed into cuts. Scoped to @project (the leakage
# guard: a source video from another project is a 404).
class CutsController < ProjectScopedController
  include VideoStreaming

  rescue_from Cuts::AddItem::InvalidRange, with: :report_failure
  rescue_from Cuts::StartPackaging::UnknownKind, with: :unknown_action
  rescue_from Cuts::Bundle::NotReady, Cuts::Master::NotReady, with: :not_found

  before_action :set_source_video
  before_action :set_cut, except: %i[analyze_topics triage]

  def show
    @room = screen
  end

  # The topics frame alone (no layout), re-fetched while the analysis runs so the
  # topics appear live when the pass finishes.
  def topics
    @room = screen
    render partial: "topics"
  end

  # The cut frame alone (no layout) — the fallback for a client without Turbo, and
  # the frame's own reload target.
  def cut
    @room = screen
    render partial: "cut"
  end

  # The render's live state, as the panels it touches. Polled while a render is in
  # flight: a finishing render changes the composition AND the stage (the mode
  # switcher, the preview panel that did not exist while there were no clips), and
  # those are three different places on the page.
  def progress
    @room = screen
    render :progress
  end

  # The packaging frame alone (no layout), re-fetched while a pass is running.
  def packaging_status
    @room = screen
    render partial: "packaging"
  end

  def analyze_topics
    Cuts::StartAnalysis.new.call(source_video: @source_video)
    redirect_to room, notice: "Analyzing the transcript for topics…"
  end

  # Record the opinion about a topic: "maybe", "discarded" or "open" (clear).
  def triage
    Cuts::Triage.new.call(source_video: @source_video, topic_id: params[:topic_id], state: params[:state])
    redirect_to room
  end

  def add_item
    Cuts::AddItem.new.call(cut: @cut, topic_id: params[:topic_id],
      start_s: params[:start_s], end_s: params[:end_s])
    refresh_panels
  end

  def remove_item
    Cuts::RemoveItem.new.call(cut: @cut, id: params[:id])
    refresh_panels
  end

  def move_item
    Cuts::MoveItem.new.call(cut: @cut, id: params[:id], direction: params[:direction])
    refresh_panels
  end

  def render_cut
    Cuts::StartRender.new.call(cut: @cut)
    redirect_to room, notice: "Rendering the clips…"
  end

  def export_cut
    Cuts::StartExport.new.call(cut: @cut, skip_master: flag(:skip_master), upscale: flag(:upscale))
    redirect_to room, notice: "Exporting the cut…"
  end

  def download_export
    path = Cuts::Bundle.new.call(cut: @cut)
    send_file path, type: "application/zip", filename: File.basename(path)
  end

  # The cut as one file — the clips concatenated. This is what the room plays.
  def master
    stream_video Cuts::Master.new.call(cut: @cut)
  end

  # `flash[:working]` engages the frame's polling on the redirected page even
  # before the job has had a chance to mark a row.
  def package
    Cuts::StartPackaging.new.call(cut: @cut, kind: params[:kind])
    flash[:working] = true
    redirect_to room, notice: "Working on the packaging…"
  end

  private

  # Composing is the one thing done over and over in this room, so it answers with
  # the panels it changed rather than a page. The full reload stays as the
  # fallback for a client without Turbo.
  def refresh_panels
    @room = screen
    respond_to do |format|
      format.turbo_stream { render :panels }
      format.html { redirect_to room }
    end
  end

  # The one place the room's payload is built. Every frame re-renders a slice of
  # the same screen, so a divergence here would make a poll disagree with the page.
  def screen = Cuts::Screen.new(@source_video, @cut).call

  def set_source_video
    @source_video = @project.source_videos.find(params[:source_video_id])
  end

  def set_cut = @cut = @source_video.active_cut

  # A bad range is the user's to fix, so it is reported in the domain's own words.
  # An unknown packaging kind gets the short line the service keeps for a person —
  # its own message names the internals, and those belong in the log.
  def report_failure(error) = redirect_to(room, alert: error.message)

  def unknown_action = redirect_to(room, alert: Cuts::StartPackaging::UNKNOWN_ALERT)

  def not_found = head(:not_found)

  def room = project_cut_room_path(@project, @source_video)

  def flag(name) = params[name] == "1"
end
