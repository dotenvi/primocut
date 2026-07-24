# Base for controllers nested under a project. Loads @project once; a missing
# project surfaces as a 404 via ActiveRecord::RecordNotFound. This is the seam
# where the PoC's per-project leakage guard (repo.get_project_live) will live
# once source videos exist (Phase 4).
class ProjectScopedController < ApplicationController
  before_action :set_project

  private

  def set_project
    @project = Project.find(params[:project_id])
  end
end
