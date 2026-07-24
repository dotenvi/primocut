require "timeout"

# Cross-cutting resilience: retry policy, backoff and error classification.
# Reused by every collection stage. `with_retry` takes an injectable `sleeper`
# so it can be tested without real waits. Ported from the PoC `resilience.py`
# (`retry` is a Ruby keyword, hence `with_retry`).
module Resilience
  # A transient transport failure worth retrying (e.g. HTTP 429/5xx). Adapters
  # raise this instead of their permanent error type when a retry might succeed.
  class TransientError < StandardError; end

  RetryPolicy = Data.define(:attempts, :base_delay, :max_delay) do
    def initialize(attempts: 3, base_delay: 1.0, max_delay: 30.0)
      super
    end
  end

  # Class names (without importing the SDKs) that indicate a transient provider error.
  TRANSIENT_NAMES = %w[
    APIConnectionError APITimeoutError APIConnectionTimeoutError
    RateLimitError InternalServerError OverloadedError
  ].freeze

  # Network-level errors that are, by their nature, worth retrying. Note the
  # connection-related Errno subset only: a missing file (ENOENT) is NOT transient.
  TRANSIENT_ERRORS = [
    TransientError, Timeout::Error, SocketError, IOError,
    Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT, Errno::EHOSTUNREACH,
    Errno::EPIPE, Errno::ENETUNREACH
  ].freeze

  module_function

  # Heuristic: is the error likely to succeed if retried?
  def transient?(error)
    status = error.respond_to?(:status_code) ? error.status_code : nil
    return true if status.is_a?(Integer) && ([ 408, 409, 429 ].include?(status) || status >= 500)
    return true if TRANSIENT_ERRORS.any? { |klass| error.is_a?(klass) }

    TRANSIENT_NAMES.include?(error.class.name)
  end

  # Run the block with retry+backoff while `retryable` holds true.
  def with_retry(policy: RetryPolicy.new, retryable: method(:transient?),
                 sleeper: ->(seconds) { sleep(seconds) }, label: "")
    last = nil
    policy.attempts.times do |attempt|
      return yield
    rescue StandardError => e
      last = e
      raise if !retryable.call(e) || attempt == policy.attempts - 1

      delay = [ policy.base_delay * (2**attempt), policy.max_delay ].min
      Rails.logger.warn(
        "retry#{label.empty? ? "" : " [#{label}]"}: attempt #{attempt + 1}/#{policy.attempts} " \
        "failed (#{e.class}: #{e.message}); waiting #{format('%.1f', delay)}s"
      )
      sleeper.call(delay)
    end
    raise last
  end
end
