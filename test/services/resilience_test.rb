require "test_helper"

# Tests for the cross-cutting resilience module (retry/backoff/classification).
# Ported from the PoC `tests/test_resilience.py`. `retry` is a Ruby keyword, so
# the runner is `Resilience.with_retry`.

# A transient error carries a retryable HTTP status; a permanent one does not.
class ResilienceTransientError < StandardError
  def status_code = 503
end

class ResiliencePermanentError < StandardError
  def status_code = 400
end

# A class named like a known transient SDK error, classified by name alone.
class RateLimitError < StandardError; end

class ResilienceTest < ActiveSupport::TestCase
  R = Resilience

  # Records the delays instead of sleeping, so tests never wait.
  def recorder
    delays = []
    [ delays, ->(seconds) { delays << seconds } ]
  end

  test "retry succeeds after transient failures" do
    calls = 0
    delays, sleeper = recorder
    result = R.with_retry(policy: R::RetryPolicy.new(attempts: 5, base_delay: 1.0), sleeper:) do
      calls += 1
      raise ResilienceTransientError if calls < 3
      "ok"
    end
    assert_equal "ok", result
    assert_equal 3, calls
    assert_equal [ 1.0, 2.0 ], delays # exponential backoff
  end

  test "retry reraises non-retryable immediately" do
    calls = 0
    delays, sleeper = recorder
    assert_raises(ResiliencePermanentError) do
      R.with_retry(policy: R::RetryPolicy.new(attempts: 5), sleeper:) do
        calls += 1
        raise ResiliencePermanentError
      end
    end
    assert_equal 1, calls # did not retry
    assert_empty delays
  end

  test "retry exhausts attempts and reraises" do
    calls = 0
    delays, sleeper = recorder
    assert_raises(ResilienceTransientError) do
      R.with_retry(policy: R::RetryPolicy.new(attempts: 3, base_delay: 1.0), sleeper:) do
        calls += 1
        raise ResilienceTransientError
      end
    end
    assert_equal 3, calls
    assert_equal [ 1.0, 2.0 ], delays # slept between the 3 attempts (2 waits)
  end

  test "backoff is capped by max_delay" do
    delays, sleeper = recorder
    assert_raises(ResilienceTransientError) do
      R.with_retry(policy: R::RetryPolicy.new(attempts: 5, base_delay: 10.0, max_delay: 15.0), sleeper:) do
        raise ResilienceTransientError
      end
    end
    assert_equal [ 10.0, 15.0, 15.0, 15.0 ], delays # 10, 20→15, 40→15, 80→15
  end

  test "transient classification" do
    assert R.transient?(ResilienceTransientError.new)      # status 503
    refute R.transient?(ResiliencePermanentError.new)      # status 400
    assert R.transient?(Resilience::TransientError.new)
    assert R.transient?(Timeout::Error.new)
    assert R.transient?(SocketError.new)
    assert R.transient?(Errno::ECONNRESET.new)
    refute R.transient?(ArgumentError.new)                 # analog of ValueError
    refute R.transient?(Errno::ENOENT.new)                 # a missing file is NOT transient
  end

  test "transient by class name" do
    assert R.transient?(RateLimitError.new)
  end
end
