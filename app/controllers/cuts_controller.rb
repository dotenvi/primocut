# The Cut Room, per source video — the working screen where a processed video's
# topics are triaged and composed into cuts. Scoped to @project (the leakage guard:
# a source video from another project is a 404). Built section by section: topics +
# triage, then composing the active cut and rendering its clips.
class CutsController < ProjectScopedController
  before_action :set_source_video
  before_action :set_cut, except: %i[analyze_topics triage]

  def show
    load_topics
    load_packaging
  end

  # The topics frame alone (no layout), re-fetched by the polling controller while
  # the analysis runs so the topics appear live when the pass finishes.
  def topics
    load_topics
    render partial: "topics"
  end

  # The cut frame alone (no layout), re-fetched while the render is in flight so the
  # clips' states update live.
  def cut
    render partial: "cut"
  end

  # Regenerate the source video's topics with the LLM (background). The video is
  # flipped to "analyzing" so the frame polls until the pass restores it to "done".
  def analyze_topics
    @source_video.update!(status: "analyzing")
    AnalyzeTopicsJob.perform_later(@source_video.id)
    redirect_to cut_room_path, notice: "Analyzing the transcript for topics…"
  end

  # Record the user's opinion about a topic: "maybe", "discarded" or "open" (clear).
  def triage
    topic = @source_video.topics.find(params[:topic_id])
    Cuts::Triage.set(@source_video, topic, params[:state])
    redirect_to cut_room_path
  end

  # Append a topic (snapshotting its range) or a manual range to the active cut.
  def add_item
    position = (@cut.cut_items.maximum(:position) || -1) + 1
    if params[:topic_id].present?
      topic = @source_video.topics.find(params[:topic_id])
      @cut.cut_items.create!(topic:, position:, start_s: topic.start_s, end_s: topic.end_s)
    else
      add_manual_range(position)
    end
    redirect_to cut_room_path
  rescue ArgumentError, TypeError
    redirect_to cut_room_path, alert: "Enter a valid start and end (end after start)."
  end

  # Remove an item from the composition (its clip goes with it), then re-pack the
  # remaining positions so they stay contiguous.
  def remove_item
    @cut.cut_items.find(params[:id]).destroy!
    repack_positions
    redirect_to cut_room_path
  end

  # Move an item one slot up or down by swapping positions with its neighbour.
  def move_item
    item = @cut.cut_items.find(params[:id])
    neighbour = neighbour_of(item, params[:direction])
    swap_positions(item, neighbour) if neighbour
    redirect_to cut_room_path
  end

  # Render the cut's clips (background). The cut is flipped to "rendering" so the
  # frame polls until the pass restores it to "rendered".
  def render_cut
    @cut.update!(status: "rendering")
    CutRenderJob.perform_later(@cut.id)
    redirect_to cut_room_path, notice: "Rendering the clips…"
  end

  # The export frame alone (no layout), re-fetched while the bundle is being built.
  def export_status
    render partial: "export"
  end

  # Export the cut into a deliverable bundle (background). The export row is seeded
  # to "queued" up front so the frame polls immediately.
  def export_cut
    export_row.update!(state: "queued", error: "")
    CutExportJob.perform_later(@cut.id, skip_master: flag(:skip_master), upscale: flag(:upscale))
    redirect_to cut_room_path, notice: "Exporting the cut…"
  end

  # Send the finished zip. A 404 until the export is done and a zip exists.
  def download_export
    export = @cut.export
    path = export&.zip_rel_path.presence && File.join(Cuts::Export.default_exports_dir, export.zip_rel_path)
    raise ActiveRecord::RecordNotFound unless export&.state_done? && path && File.exist?(path)

    send_file path, type: "application/zip", filename: File.basename(path)
  end

  # The packaging frame alone (no layout), re-fetched while a pass is running.
  def packaging_status
    load_packaging
    render partial: "packaging"
  end

  # Run one packaging action for the cut (opt-in AI): titles, briefs, frame
  # extraction, frame ranking, or the audience match. `flash[:working]` engages the
  # frame's polling on the redirected page even before the job has marked a row.
  def package
    job_for(params[:kind]) or return redirect_to cut_room_path, alert: "Unknown packaging action."
    flash[:working] = true
    redirect_to cut_room_path, notice: "Working on the packaging…"
  end

  private

  # Enqueue the job for a packaging kind; nil for an unknown kind.
  def job_for(kind)
    case kind
    when "title", "thumb_brief" then CutPackagingJob.perform_later(@cut.id, kind:)
    when "frames" then ExtractCutFramesJob.perform_later(@cut.id)
    when "rank" then RankCutFramesJob.perform_later(@cut.id)
    when "audience" then MatchAudienceJob.perform_later(@source_video.id)
    end
  end

  def set_source_video
    @source_video = @project.source_videos.find(params[:source_video_id])
  end

  # The active cut: a source video gets a default "Cut 1" lazily.
  def set_cut
    @cut = @source_video.cuts.order(:created_at).first || @source_video.cuts.create!
  end

  def load_topics
    @topics = @source_video.topics.ordered
    @triage = @source_video.topic_triages.index_by(&:topic_id)
    @cut_topic_ids = @cut.cut_items.where.not(topic_id: nil).pluck(:topic_id).to_set
  end

  # {cut_item_id => {kind => CutPackaging}} plus the source video's audience match.
  def load_packaging
    @packaging = CutPackaging.where(cut_id: @cut.id).group_by(&:cut_item_id)
                            .transform_values { |rows| rows.index_by(&:kind) }
    @audience = @source_video.audience_match
  end

  def add_manual_range(position)
    start_s = Float(params[:start_s])
    end_s = Float(params[:end_s])
    raise ArgumentError unless end_s > start_s

    @cut.cut_items.create!(position:, start_s:, end_s:)
  end

  def repack_positions
    @cut.cut_items.order(:position).each_with_index do |item, i|
      item.update_column(:position, i) unless item.position == i
    end
  end

  def neighbour_of(item, direction)
    if direction == "up"
      @cut.cut_items.where(position: ...item.position).order(position: :desc).first
    else
      @cut.cut_items.where("position > ?", item.position).order(:position).first
    end
  end

  def swap_positions(a, b)
    a_pos = a.position
    a.update!(position: b.position)
    b.update!(position: a_pos)
  end

  def cut_room_path
    project_cut_room_path(@project, @source_video)
  end

  def export_row
    @cut.export || @cut.create_export!(source_video_id: @source_video.id)
  end

  def flag(name)
    params[name] == "1"
  end
end
