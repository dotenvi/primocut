module Navigation
  # Everything the sidebar chrome renders: the projects with their tracked-channel
  # counts, and the API quota spent so far in the current quota day. PURE READ.
  #
  # This is chrome, not a screen's payload — it renders on every page, so the two
  # reads it costs are bounded on purpose: one grouped count instead of a COUNT
  # per project, and a quota sum scoped to Google's current day rather than the
  # whole history.
  class Sidebar
    Result = Struct.new(:projects, :channel_counts, :quota_used, :quota_budget, keyword_init: true) do
      def channel_count(project) = channel_counts.fetch(project.id, 0)
    end

    def initialize(now: Time.current)
      @now = now
    end

    def call
      projects = ::Project.order(:name).to_a

      Result.new(
        projects: projects,
        channel_counts: ProjectChannel.where(project_id: projects.map(&:id)).group(:project_id).count,
        quota_used: Activity::QuotaUsed.new(since: Adapters::YoutubeApi.quota_day_start(@now)).call,
        quota_budget: Adapters::YoutubeApi::DAILY_QUOTA_UNITS
      )
    end
  end
end
