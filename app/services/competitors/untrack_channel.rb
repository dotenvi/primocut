module Competitors
  # Stop tracking a competitor channel in a project. Nothing collected is deleted:
  # the link goes, and a channel no project tracks any more is deactivated so the
  # snapshot cycle stops spending quota on it.
  #
  # Exists so the controller has the same shape on both sides — [[TrackChannel]]
  # and this — instead of reaching into ChannelRegistration for one of them.
  class UntrackChannel
    def call(project:, youtube_channel_id:)
      ChannelRegistration.detach(project_id: project.id, youtube_channel_id: youtube_channel_id)
    end
  end
end
