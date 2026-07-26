module Radar
  # Everything the Radar screen renders, composed once: the project filter and its
  # chips, the two paginated feeds, the channel-spread strips for the cards that
  # are actually on screen, and the open ops alerts. PURE READ.
  #
  # The page sizes live here, not in the controller: they are what makes the two
  # feeds different (a tall card versus a compact row), and the strips can only be
  # computed once the visible slice is known — that ordering is the whole reason
  # this composition is one object instead of four calls in an action.
  class Screen
    NEW_PER_PAGE = 6    # "New" cards are tall — keep the actionable feed short
    SEEN_PER_PAGE = 15  # "Earlier" rows are compact, so a page holds more

    Result = Struct.new(:projects, :project, :unseen, :seen, :spread, :alerts, keyword_init: true)

    def initialize(project_id: nil, new_page: nil, seen_page: nil,
                   config: Metrics::Config.new, now: Time.current)
      @project_id = project_id
      @new_page = new_page
      @seen_page = seen_page
      @config = config
      @now = now
    end

    def call
      feed = Feed.new(project: project).call
      unseen = Page.new(feed.unseen, page: @new_page, per_page: NEW_PER_PAGE)
      seen = Page.new(feed.seen, page: @seen_page, per_page: SEEN_PER_PAGE)

      Result.new(
        projects: projects, project: project, unseen: unseen, seen: seen,
        spread: Spread.new(unseen.rows, config: @config, now: @now).call,
        alerts: Alerts.new.call
      )
    end

    private

    def projects = @projects ||= Project.order(:name).to_a

    # An unknown project id falls back to the unfiltered feed rather than 404ing:
    # the filter is a chip, and a stale bookmark should still show the Radar.
    def project
      return @project if defined?(@project)

      @project = @project_id.present? ? projects.find { |p| p.id == @project_id.to_i } : nil
    end
  end
end
