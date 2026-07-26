module OwnChannelsHelper
  # A saved channel confirms; a rejected one reports why, in the model's own
  # words, so the duplicate case reads as "already in this niche" rather than as a
  # generic failure. Returns a flash hash — the caller only redirects.
  def own_channel_added(channel)
    return { notice: "Added #{own_channel_label(channel)} to this niche." } if channel.persisted?

    { alert: channel.errors.full_messages.to_sentence }
  end

  def own_channel_removed(channel)
    { notice: "Removed #{own_channel_label(channel)} from this niche." }
  end

  # The handle is what a person recognises; the url is the fallback, and it is
  # always present because the model requires it.
  def own_channel_label(channel) = channel.handle.presence || channel.channel_url
end
