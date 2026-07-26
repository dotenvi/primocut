module Sources
  # Put a settled source video back through the pipeline.
  #
  # Refused while it is still in flight: the queue would then hold two runs for
  # the same video, and the second would fight the first for the GPU slot and
  # overwrite its progress. The lookup is scoped to the project, so another
  # project's video does not exist here.
  class Rerun
    class StillRunning < StandardError; end

    def call(project:, id:)
      video = project.source_videos.find(id)
      raise StillRunning, "That video is already being processed." if video.active?

      video.update!(status: "queued")
      SourceVideoPipelineJob.perform_later(video.id)
      video
    end
  end
end
