require "io/console"

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
    MIN_DETAIL = 8 # below this a trimmed detail says nothing; drop it instead
    BAR_KEEP_DETAIL = 24 # the bar is worth its 18 columns only if the detail still reads
    WIDE = 80 # above this the stage column is affordable; below it the detail wins
    FALLBACK_WIDTH = 80

    def initialize(io: $stdout, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @io = io
      @clock = clock
      @live = io.respond_to?(:tty?) && io.tty?
      @color = @live && ENV["NO_COLOR"].nil?
      @fallback_width = (ENV["COLUMNS"] || FALLBACK_WIDTH).to_i.clamp(20, 400) - 1
      @mutex = Mutex.new
      @started_at = @stage_started_at = clock.call
      @stage = nil
      @progress = 0
      @detail = nil
      @frame = 0
      @closed = false
      @ticker = nil
      @drawn = [ 0, nil ] # [visible length, the width it was drawn at]
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
        if @live
          cols = width
          wipe(cols)
          @drawn = [ 0, cols ] # the puts below ends the line the wipe just cleared
        end
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
      cols = width
      wipe(cols)
      from = @progress >= 100 ? @started_at : @stage_started_at
      head = "  ✓ #{label(cols)}"
      line = cols <= head.length ? head[0, cols] : "#{head}#{tail(cols - head.length, from)}"
      @io.puts(paint(line, :green))
      @drawn = [ 0, cols ] # the newline ends the live line; nothing is left to wipe
    end

    def redraw
      cols = width
      wipe(cols)
      line = live_line(cols)
      @io.print("\e[2K\r#{line}")
      @drawn = [ visible(line), cols ]
      @io.flush
    end

    # A resize reflows what was already drawn: the live line can end up spanning
    # rows a single `\e[2K` cannot reach, and those rows then stay on screen for
    # the rest of the run — one stuck line per resize. Wipe upwards through the
    # rows the old line occupies at the NEW width before drawing over it.
    def wipe(cols)
      length, drawn_cols = @drawn
      @io.print("\e[2K\r")
      return if drawn_cols.nil? || drawn_cols == cols || length.zero?

      ((length - 1) / cols).times { @io.print("\e[1A\e[2K\r") }
    end

    def clear = @io.print("\e[2K\r")

    def visible(line) = line.gsub(/\e\[[0-9;]*m/, "").length

    # Indented to the same column as the settled lines it will be replaced by, so
    # the stage names form one column as the run scrolls.
    def live_line(cols)
      head = "  #{SPINNER[@frame % SPINNER.size]} #{label(cols)}"
      meter = " #{@progress.to_s.rjust(3)}%"
      budget = cols - head.length - meter.length
      # Narrower than the stage name itself: the stage alone, still one line.
      return head[0, cols] if budget < MIN_DETAIL

      # The bar is the first thing dropped when the terminal is tight — it says
      # what the percentage beside it already says, in eighteen more columns, and
      # a bar bought with the sub-step is a bad trade.
      if worth_the_bar?(budget - BAR_WIDTH - 2)
        "#{head}#{bar}#{meter}#{tail(budget - BAR_WIDTH - 2)}"
      else
        "#{head}#{meter}#{tail(budget)}"
      end
    end

    # The padding aligns the stage names into a column as the run scrolls. That is
    # worth ten columns on a wide terminal and not worth them on a narrow one,
    # where the same columns carry the channel and the sub-step instead.
    def label(cols) = cols >= WIDE ? @stage.to_s.ljust(STAGE_WIDTH) : @stage.to_s

    def worth_the_bar?(budget)
      needed = " · #{elapsed(@stage_started_at)}".length
      needed += 3 + BAR_KEEP_DETAIL if @detail
      budget >= needed
    end

    def bar
      filled = (BAR_WIDTH * @progress.clamp(0, 100) / 100.0).round
      paint("[#{'█' * filled}#{'░' * (BAR_WIDTH - filled)}]", :dim)
    end

    # What follows the meter, fitted into `budget`. The detail is the part that
    # gives way: the stage, the meter and the clock are what the line exists to
    # report, and a detail cut short still reads as progress. The ellipsis is
    # there so a trimmed detail never passes for a complete one.
    def tail(budget, from = @stage_started_at)
      time = " · #{elapsed(from)}"
      room = budget - time.length - 3 # 3 = the " · " before the detail
      return time[0, budget.clamp(0, time.length)] if @detail.nil? || room < MIN_DETAIL

      detail = @detail.length <= room ? @detail : "#{@detail[0, room - 1]}…"
      " · #{detail}#{time}"
    end

    # Re-read every frame, because a terminal can be resized mid-run. One column
    # is left unwritten: filling the last cell is what makes a terminal wrap, and
    # a wrapped line is what breaks the in-place redraw — `\e[2K\r` would clear
    # only the overflow and leave the first half on screen, once per frame.
    def width
      return @fallback_width unless @io.respond_to?(:winsize)

      @io.winsize[1].clamp(20, 400) - 1
    rescue StandardError
      @fallback_width
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
