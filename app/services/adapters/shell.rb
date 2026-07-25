require "open3"

module Adapters
  # Minimal subprocess seam shared by the shell-out adapters (yt-dlp, chat).
  # `capture` returns stdout for JSON-producing commands; `run` is for commands
  # whose product is a file on disk. Both raise CommandError on a non-zero exit,
  # folding a slice of stderr into the message. Injected as a collaborator so the
  # adapters are testable without touching the real binaries.
  #
  # `stdin_data: ""` reproduces the PoC's stdin=DEVNULL: without it a child run in
  # the background (a job work-horse) can try to read the terminal, get SIGTTIN
  # and STOP. See the rationale in the PoC `download/audio.py`.
  class Shell
    class CommandError < StandardError; end

    def capture(cmd)
      out, err, status = Open3.capture3(*cmd, stdin_data: "")
      raise CommandError, error_message(cmd, status, err) unless status.success?

      out
    end

    def run(cmd)
      _out, err, status = Open3.capture3(*cmd, stdin_data: "")
      raise CommandError, error_message(cmd, status, err) unless status.success?

      nil
    end

    private

    def error_message(cmd, status, err)
      "#{cmd.first} exited #{status.exitstatus}: #{err.to_s.strip[0, 300]}"
    end
  end
end
