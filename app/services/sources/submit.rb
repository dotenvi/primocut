module Sources
  # Accept a YouTube link into a project and start its pipeline.
  #
  # Re-submitting a link the project already holds re-runs it rather than creating
  # a second row: the video id is the identity, so the same source cannot be
  # queued twice side by side under two urls.
  class Submit
    # The one failure a request path answers for: the link is not usable, or the
    # record it would create is not valid. A bug anywhere else still crashes.
    class Failed < StandardError; end

    def call(project:, url:)
      canonical = canonical_url(url)
      youtube_id = Adapters::Ytdlp.extract_video_id(canonical)

      video = project.source_videos.find_or_initialize_by(youtube_id: youtube_id)
      video.assign_attributes(url: canonical, status: "queued")
      save!(video)

      SourceVideoPipelineJob.perform_later(video.id)
      video
    end

    private

    # Validation is the only step that rejects a link, so the rescue wraps it
    # alone — anything else raising here is a bug, not a bad paste.
    def canonical_url(url)
      Adapters::Ytdlp.validate_youtube_url(url)
    rescue Adapters::Ytdlp::Error => e
      raise Failed, e.message
    end

    def save!(video)
      video.save!
    rescue ActiveRecord::RecordInvalid => e
      raise Failed, e.record.errors.full_messages.to_sentence.presence || e.message
    end
  end
end
