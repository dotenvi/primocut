# The full activity log across projects, newest first, with its quota accounting.
class ActivityController < ApplicationController
  def show
    @log = Activity::Log.new(before_id: params[:before_id]).call
  end
end
