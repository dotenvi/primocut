class RadarController < ApplicationController
  # The cross-project niche feed: unseen events first, then earlier (seen) ones.
  # Events are emitted by the snapshot cycle (Phase 3), so this reads an empty feed
  # until collection runs — the screen degrades to an honest empty state.
  def show
    @projects = Project.order(:name)
    @project = @projects.find_by(id: params[:project_id]) if params[:project_id].present?

    scope = Event.where(category: "niche")
    scope = scope.where(project_id: @project.id) if @project
    @unseen = scope.where(seen_at: nil).order(occurred_at: :desc).limit(50)
    @seen = scope.where.not(seen_at: nil).order(occurred_at: :desc).limit(50)
  end
end
