module Competitors
  # Track a competitor channel in a project: resolve the reference against the
  # API, link it, and collect it if nobody has yet.
  #
  # This exists so the wiring lives here and not in a controller: the API client
  # is a constructor dependency with a real default, which is the only shape a
  # test can replace without monkeypatching. `from_env` is evaluated only when no
  # client is supplied, so injecting a fake never needs a key in the environment.
  class TrackChannel
    # The single failure a request path answers for: the reference could not be
    # resolved, or the collection could not be queued. One error, caught at the
    # boundary — a bug anywhere else still crashes loudly instead of arriving as
    # a polite flash message.
    class Failed < StandardError; end

    def initialize(client: nil, registration: nil)
      @client = client
      @registration = registration
    end

    def call(project:, reference:)
      parse!(reference)
      registration.register(project_id: project.id, reference: reference.to_s)
    rescue Adapters::YoutubeApi::Error, QueueUnavailableError => e
      raise Failed, e.message
    end

    private

    # Parsing is the only step that legitimately raises ArgumentError, so the
    # rescue wraps it alone. Catching ArgumentError around the whole call would
    # turn any argument bug in the stack into a "bad reference" message.
    def parse!(reference)
      Adapters::YoutubeApi.parse_channel_reference(reference.to_s)
    rescue ArgumentError => e
      raise Failed, e.message
    end

    def registration
      @registration ||= ChannelRegistration.new(client: @client || Adapters::YoutubeApi.from_env)
    end
  end
end
