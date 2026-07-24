module Competitors
  # Read-only collection settings, injected into the collection services (DIP)
  # with the PoC defaults. Ported from the `youtube_*` knobs of the PoC
  # `config.Settings`. A plain value object (not Rails.application.config), like
  # [[Metrics::Config]]: a service takes `config:` in its constructor, so a test
  # overrides one knob without touching global state.
  class Config
    attr_reader :backfill_limit, :short_max_seconds, :recent_days,
                :uploads_scan_limit, :comment_pages

    def initialize(
      backfill_limit: 120,
      short_max_seconds: 180,
      recent_days: 7,
      uploads_scan_limit: 15,
      comment_pages: 2
    )
      @backfill_limit = backfill_limit
      @short_max_seconds = short_max_seconds
      @recent_days = recent_days
      @uploads_scan_limit = uploads_scan_limit
      @comment_pages = comment_pages
    end
  end
end
