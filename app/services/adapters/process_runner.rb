require "open3"

module Adapters
  # Runs a child process under a killable timeout, the way the sidecar boundary
  # spike proved is required (docs §5.2):
  #
  # - spawn in its OWN process group (`pgroup: true`) so a timeout can kill the
  #   whole tree with `Process.kill("-KILL", pgid)`. Killing only the parent would
  #   strand a CUDA process holding the GPU — the exact hazard the GPU serialization
  #   exists to avoid;
  # - drain stdout and stderr in threads so a chatty child (500 lines of CUDA
  #   noise) can never deadlock by filling a pipe the reader is not draining.
  #
  # Returned as a value; callers decide what a non-zero exit means.
  class ProcessRunner
    class TimeoutError < StandardError; end

    Result = Data.define(:stdout, :stderr, :status)

    def call(cmd, timeout: nil)
      Open3.popen3(*cmd, pgroup: true) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        out = +""
        err = +""
        readers = [
          Thread.new { stdout.each_line { |line| out << line } },
          Thread.new { stderr.each_line { |line| err << line } }
        ]

        if timeout && wait_thr.join(timeout).nil?
          # pgroup: true makes the child its own group leader, so pid == pgid.
          kill_group(wait_thr.pid)
          readers.each(&:join)
          raise TimeoutError, "#{cmd.first} exceeded #{timeout}s and was killed"
        end

        wait_thr.join
        readers.each(&:join)
        Result.new(stdout: out, stderr: err, status: wait_thr.value)
      end
    end

    private

    def kill_group(pid)
      Process.kill("-KILL", pid)
    rescue Errno::ESRCH
      # already gone between the timeout and the signal — nothing to kill
    end
  end
end
