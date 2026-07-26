module Settings
  # Stop publishing to a channel in this niche. Returns the removed record so the
  # confirmation can still name it.
  #
  # The lookup is scoped to the project, which is the leakage guard: another
  # project's channel does not exist here, so it is a 404 rather than a delete.
  class RemoveOwnChannel
    def call(project:, id:)
      channel = project.own_channels.find(id)
      channel.destroy!
      channel
    end
  end
end
