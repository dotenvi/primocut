class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :sidebar

  private

  # The navigation chrome, composed once per request. Resolved lazily rather than
  # in a before_action so a layout-less render — the polling frames re-fetch a
  # single row every couple of seconds — never pays for a sidebar nobody draws.
  def sidebar = @sidebar ||= Navigation::Sidebar.new.call
end
