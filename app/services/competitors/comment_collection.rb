module Competitors
  # Automatic collection of an outlier's top comments (deterministic, no LLM). Runs
  # inside the snapshot cycle: comments cost YouTube quota but no LLM call, so the
  # schedule may spend on them — only the synthesis over them is a manual, paid pass.
  #
  # A CONSUMER of `outlier_crossed`, not its own detector. Crossing detection lives
  # in one place — the emission step ([[Competitors::OutlierEmission]]) that runs
  # just before this. This step re-scores nothing: it reads the videos that have an
  # `outlier_crossed` event and collects the ones still owed comments, so the two
  # can never disagree (collecting twice, or never).
  #
  # Collect-once by design: an outlier's comment set is fetched a single time (the
  # `comments_state` terminal guard stops a re-cross up the band ladder from
  # re-collecting) and only an explicit regeneration fetches it again. An `"error"`
  # is NOT terminal, so the video stays due and is retried on a later cycle — even
  # though no new event fires for it. Resilience: selection and every video are
  # isolated — a disabled or failing video is recorded and the cycle carries on.
  # Ported from the PoC `worker/comment_collection.py`.
  class CommentCollection
    STATE_DONE = "done"
    STATE_DISABLED = "disabled"
    STATE_ERROR = "error"

    # States that stop the cycle asking again. "error" is absent on purpose: a
    # failed fetch is worth one more try next cycle, a disabled thread never is.
    TERMINAL_STATES = [ STATE_DONE, STATE_DISABLED ].freeze

    def initialize(client:, config: Config.new)
      @client = client
      @config = config
    end

    # Collect the top comments of every definitive outlier of these channels that
    # still needs them. Returns how many videos were collected. Never raises: a
    # failure here must not cost the cycle its snapshots.
    def call(channels, now: Time.current)
      collected = 0
      select_due(channels).each do |video|
        collect_video(video, now:)
        collected += 1
        Rails.logger.info("comments: collected for outlier #{video.youtube_video_id}")
      rescue Adapters::YoutubeApi::CommentsDisabledError => e
        Rails.logger.info("comments: disabled on #{video.youtube_video_id}")
        record_state(video, STATE_DISABLED, e.message)
      rescue StandardError => e # per-video isolation: log, record, keep going
        Rails.logger.error("comments: video #{video.youtube_video_id} failed: #{e.message}")
        record_state(video, STATE_ERROR, e.message)
      end
      collected
    end

    # Fetch and store one video's top comments; record the `done` state. Returns how
    # many were stored. Public because an explicit regeneration (a later slice)
    # reuses it — the fetch is the same, only the trigger differs.
    def collect_video(video, now: Time.current)
      # Network read, deliberately outside the write transaction.
      comments = @client.list_top_comments(video.youtube_video_id, pages: @config.comment_pages)
      ActiveRecord::Base.transaction do
        stored = replace_comments(video, comments, now)
        video.update!(comments_state: STATE_DONE, comments_error: "", comments_fetched_at: now)
        stored
      end
    end

    private

    def select_due(channels)
      channel_ids = channels.map(&:id)
      return [] if channel_ids.empty?

      video_ids = Event
        .where(event_type: "outlier_crossed", competitor_channel_id: channel_ids)
        .where.not(competitor_video_id: nil)
        .distinct.pluck(:competitor_video_id)
      CompetitorVideo.where(id: video_ids).where.not(comments_state: TERMINAL_STATES).to_a
    rescue StandardError => e # never let selection break the collection cycle
      Rails.logger.error("comment collection: could not select outliers: #{e.message}")
      []
    end

    # Store a freshly collected comment set, dropping whatever was there. A replace
    # (not a merge) keeps the stored set exactly what the API returned last.
    def replace_comments(video, comments, now)
      video.video_comments.delete_all
      seen = Set.new
      stored = 0
      comments.each do |c|
        # Paging is not a snapshot: a comment posted mid-fetch can shift the
        # relevance order and re-emit one we already have. Drop the repeat rather
        # than trip the (competitor_video_id, comment_id) unique index.
        next if seen.include?(c.comment_id)

        seen << c.comment_id
        video.video_comments.create!(
          comment_id: c.comment_id, text: c.text, like_count: c.like_count, author: c.author, fetched_at: now
        )
        stored += 1
      end
      stored
    end

    def record_state(video, state, message)
      video.update!(comments_state: state, comments_error: message)
    rescue StandardError => e # a video we cannot even flag must not abort the cycle
      Rails.logger.error("comments: could not record the state of #{video.youtube_video_id}: #{e.message}")
    end
  end
end
