module Sources
  # The project's submitted source videos, newest first, with the two things the
  # list reports beyond their own row: how many topics each one yielded, and the
  # run whose progress is shown. PURE READ.
  #
  # Both are resolved in one query each for the whole page — the list re-fetches
  # itself while anything is in flight, so a per-row lookup would turn a poll into
  # a scan.
  class Screen
    Row = Struct.new(:source_video, :topic_count, :job, keyword_init: true) do
      def id = source_video.id
      def title = source_video.title.presence || source_video.youtube_id
      def channel = source_video.channel.presence
      def active? = source_video.active?
      def failed? = source_video.status == "error"
      # Anything not in flight can be run again — including a finished video,
      # which is the whole point of re-running: fresh metadata, a new transcript,
      # regenerated topics. Only a run already working is refused, and the same
      # rule lives in Sources::Rerun so the button and the service agree.
      def rerunnable? = !active?
      def cuttable? = source_video.transcript.present?
    end

    Result = Struct.new(:rows, :opened, :adding, keyword_init: true) do
      def any? = rows.any?
      def polling? = rows.any?(&:active?)
      def opened? = opened.present?
      # The submit form is a disclosure, closed until asked for — the screen is
      # for reading what has been processed, not for a permanently open field.
      def adding? = adding.present?
    end

    def initialize(project, opened_id: nil, adding: false)
      @project = project
      @opened_id = opened_id
      @adding = adding
    end

    def call
      videos = @project.source_videos.includes(:transcript).order(created_at: :desc).to_a
      counts = topic_counts(videos)
      jobs = latest_jobs(videos)

      rows = videos.map do |video|
        Row.new(source_video: video, topic_count: counts.fetch(video.id, 0), job: jobs[video.id])
      end

      Result.new(rows: rows, adding: @adding,
                 opened: rows.find { |row| row.id.to_s == @opened_id.to_s })
    end

    private

    def topic_counts(videos)
      return {} if videos.empty?

      Topic.where(source_video_id: videos.map(&:id)).group(:source_video_id).count
    end

    # Ascending order means the last row written per video is its most recent run.
    def latest_jobs(videos)
      return {} if videos.empty?

      PipelineJob.where(source_video_id: videos.map(&:id))
                 .order(:created_at, :id)
                 .index_by(&:source_video_id)
    end
  end
end
