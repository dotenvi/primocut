# The global Radar: the cross-project niche feed and its seen-state write.
# Composition lives in `Radar::Screen`, so this stays params → service → render.
class RadarController < ApplicationController
  def show
    @radar = Radar::Screen.new(
      project_id: params[:project_id], new_page: params[:new_page], seen_page: params[:seen_page]
    ).call
  end

  # Clearing the feed is a write, so it answers a POST; the 303 keeps Turbo from
  # re-issuing it as part of following the redirect.
  def mark_seen
    Radar::MarkSeen.new.call
    redirect_to root_path(project_id: params[:project_id].presence), status: :see_other
  end
end
