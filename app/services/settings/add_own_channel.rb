module Settings
  # Add a channel you publish to in this niche. Returns the record — saved, or
  # unsaved carrying its reasons, so the caller only has to render.
  #
  # Which fields a person supplies is decided here, not by whatever a form posted:
  # `title` is stored but never typed, so it stays out. Whitespace is stripped and
  # a blank role becomes NULL, because " main " and "main" are the same role and
  # the column is nullable on purpose.
  class AddOwnChannel
    FIELDS = %i[channel_url handle role].freeze

    def call(project:, attributes:)
      project.own_channels.create(normalize(attributes))
    end

    private

    def normalize(attributes)
      attrs = attributes.to_h.symbolize_keys.slice(*FIELDS)
      {
        channel_url: attrs[:channel_url].to_s.strip,
        handle: attrs[:handle].to_s.strip,
        role: attrs[:role].to_s.strip.presence
      }
    end
  end
end
