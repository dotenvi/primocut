require "test_helper"
require "rbconfig"

# Real process control — the sidecar boundary's whole point (docs §5.2): the
# runner must capture output, report the exit status, drain a chatty child
# without deadlocking, and kill a hung one by timeout. Exercised with short Ruby
# subprocesses (no GPU, no sidecar).
class Adapters::ProcessRunnerTest < ActiveSupport::TestCase
  Runner = Adapters::ProcessRunner
  RUBY = RbConfig.ruby

  test "captures stdout and a successful status" do
    result = Runner.new.call([ RUBY, "-e", "puts 'hello'" ])
    assert_equal "hello\n", result.stdout
    assert result.status.success?
  end

  test "reports a non-zero exit without raising" do
    result = Runner.new.call([ RUBY, "-e", "exit 3" ])
    assert_not result.status.success?
    assert_equal 3, result.status.exitstatus
  end

  test "drains a chatty child without deadlocking" do
    result = Runner.new.call([ RUBY, "-e", "1000.times { |i| warn i }; puts 'done'" ])
    assert_equal "done\n", result.stdout
    assert_equal 1000, result.stderr.lines.size
  end

  test "kills a hung child by timeout" do
    runner = Runner.new
    started = Time.now
    assert_raises(Runner::TimeoutError) do
      runner.call([ RUBY, "-e", "sleep 5" ], timeout: 0.3)
    end
    assert_operator Time.now - started, :<, 2.0, "should not wait for the child to finish"
  end
end
