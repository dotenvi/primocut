module Primocut
  # The reporter the CLI injects into the long-running cores, so the terminal
  # shows what a command is doing while it does it. It satisfies BOTH reporter
  # contracts in the codebase — `Pipeline::Runner`'s (which also passes
  # `video_status:`) and `Competitors::SnapshotCycle`'s — because the two commands
  # need the identical display and the keyword splat absorbs the difference.
  # It is presentation, not domain, which is why it lives beside the CLI.
  #
  # Two modes, chosen by the destination:
  #   - a terminal gets ONE line redrawn in place (spinner, bar, elapsed), with
  #     each finished stage settling into a permanent line above it;
  #   - anything else (a pipe, a redirect, CI, the test suite) gets plain
  #     append-only lines with no escape codes — a redraw is noise in a log file.
  #
  # A ticker thread advances the spinner and the clock between updates. It is not
  # decoration: the calls that motivated this reporter (a video list, the write
  # transaction, transcription) report nothing for seconds to minutes, and a
  # frozen line is exactly the "is it hung?" it exists to answer.
  class ConsoleReporter
    SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
    BAR_WIDTH = 16
    STAGE_WIDTH = 18 # the longest stage name in either core, plus a space
    TICK = 0.1
    COLORS = { green: 32, yellow: 33, dim: 90 }.freeze

    def initialize(io: $stdout, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @io = io
      @clock = clock
      @live = io.respond_to?(:tty?) && io.tty?
      @color = @live && ENV["NO_COLOR"].nil?
      @mutex = Mutex.new
      @started_at = @stage_started_at = clock.call
      @stage = nil
      @progress = 0
      @detail = nil
      @frame = 0
      @closed = false
      @ticker = nil
    end

    # `**` swallows `video_status:` — the Pipeline reporter contract carries a
    # persistence concern this reporter has no business with.
    def update(stage:, progress:, detail: nil, **)
      @mutex.synchronize do
        next if @closed

        changed = stage != @stage
        if changed
          settle if @live && @stage
          @stage = stage
          @stage_started_at = @clock.call
        end
        @progress = progress
        @detail = detail

        if @live
          start_ticker
          redraw
        elsif changed
          # Only transitions print here: a detail-only update ("thumbs 7/15") is
          # one line of a redraw, but fifteen lines of a log file.
          @io.puts("[#{elapsed(@started_at)}] #{stage}")
          @io.flush
        end
      end
    end

    def warn(message)
      @mutex.synchronize do
        clear if @live
        @io.puts(paint("  ! #{message}", :yellow))
        redraw if @live
        @io.flush
      end
    end

    # Settles the live line so the caller can print its own summary underneath.
    # Idempotent: the CLI calls it on the happy path and again from an `ensure`,
    # so an abort never leaves a half-drawn line behind.
    def close
      @mutex.synchronize do
        next if @closed

        @closed = true
        settle if @live && @stage
        @io.flush
      end
      stop_ticker # outside the lock: the ticker takes it too, and join would deadlock
    end

    private

    # The finished stage, kept on screen with the duration it took. The timestamp
    # is the whole point of settling rather than just erasing. The closing stage
    # is timed from the start of the run: a terminal stage takes no time of its
    # own, and what the operator wants there is the total.
    def settle
      clear
      from = @progress >= 100 ? @started_at : @stage_started_at
      @io.puts(paint("  ✓ #{@stage.to_s.ljust(STAGE_WIDTH)}#{suffix(from)}", :green))
    end

    def redraw
      @io.print("\e[2K\r#{live_line}")
      @io.flush
    end

    def clear = @io.print("\e[2K\r")

    # Indented to the same column as the settled lines it will be replaced by, so
    # the stage names form one column as the run scrolls.
    def live_line
      spin = SPINNER[@frame % SPINNER.size]
      "  #{spin} #{@stage.to_s.ljust(STAGE_WIDTH)}#{bar} #{@progress.to_s.rjust(3)}%#{suffix}"
    end

    def bar
      filled = (BAR_WIDTH * @progress.clamp(0, 100) / 100.0).round
      paint("[#{'█' * filled}#{'░' * (BAR_WIDTH - filled)}]", :dim)
    end

    def suffix(from = @stage_started_at)
      parts = [ @detail, elapsed(from) ].compact
      " · #{parts.join(' · ')}"
    end

    def elapsed(from)
      seconds = @clock.call - from
      seconds < 60 ? format("%.1fs", seconds) : format("%d:%02d", seconds / 60, seconds % 60)
    end

    def paint(text, color)
      @color ? "\e[#{COLORS.fetch(color)}m#{text}\e[0m" : text
    end

    def start_ticker
      return if @ticker

      @ticker = Thread.new do
        loop do
          sleep(TICK)
          done = @mutex.synchronize do
            next true if @closed

            @frame += 1
            redraw
            false
          end
          break if done
        end
      rescue StandardError
        nil # a display thread must never take the command down with it
      end
    end

    def stop_ticker
      @ticker&.join(TICK * 3)
      @ticker&.kill
      @ticker = nil
    end
  end
end
