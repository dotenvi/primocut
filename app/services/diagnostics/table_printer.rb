module Diagnostics
  # Renders a doctor report as a bordered, colour-coded table (the Rich-table look
  # the PoC `cli.py::doctor` had), plus the per-failure fix hints and a summary
  # line. Colours are ANSI, emitted only to a TTY (auto-off when piped or in CI),
  # so nothing external is needed. Returns whether the environment is healthy
  # (no hard failure); the rake task turns that into the exit code.
  class TablePrinter
    LABEL = { ok: "OK", warn: "WARN", failed: "FAILED" }.freeze
    STATUS_COLOR = { ok: :green, warn: :yellow, failed: :red }.freeze
    SGR = { bold: 1, dim: 2, red: 31, green: 32, yellow: 33, cyan: 36 }.freeze

    HEADERS = %w[Check Status Detail].freeze

    def initialize(io: $stdout, color: nil, width: nil)
      @io = io
      @color = color.nil? ? io.tty? : color
      @width = width || terminal_width
    end

    def call(checks)
      name_w = width_of(checks.map(&:name), HEADERS[0])
      status_w = width_of(LABEL.values, HEADERS[1])
      detail_w = [ @width - name_w - status_w - 10, 24 ].max

      @io.puts colorize("primocut doctor", :bold, :cyan)
      @io.puts border("┌", "┬", "┐", name_w, status_w, detail_w)
      @io.puts header_row(name_w, status_w, detail_w)
      @io.puts border("├", "┼", "┤", name_w, status_w, detail_w)
      checks.each_with_index do |c, i|
        @io.puts border("├", "┼", "┤", name_w, status_w, detail_w) if i.positive?
        emit_check(c, name_w, status_w, detail_w)
      end
      @io.puts border("└", "┴", "┘", name_w, status_w, detail_w)

      emit_footer(checks)
      checks.none?(&:failed?)
    end

    private

    def emit_check(check, name_w, status_w, detail_w)
      lines = wrap(check.detail, detail_w)
      lines.each_with_index do |line, i|
        name = i.zero? ? cell(check.name, name_w, :bold) : blank(name_w)
        status = i.zero? ? cell(LABEL.fetch(check.status), status_w, :bold, STATUS_COLOR.fetch(check.status)) : blank(status_w)
        @io.puts "│ #{name} │ #{status} │ #{cell(line, detail_w)} │"
      end
    end

    def emit_footer(checks)
      failures = checks.select(&:failed?)
      warnings = checks.select(&:warn)

      if failures.any?
        @io.puts
        @io.puts colorize("How to fix:", :bold)
        failures.each { |c| @io.puts "  #{colorize('•', :red)} #{colorize(c.name, :bold)}: #{c.fix}" if c.fix }
      end
      warnings.each { |c| @io.puts "\n  #{colorize('note', :yellow)} — #{c.name}: #{c.fix}" if c.fix }

      @io.puts
      if failures.any?
        @io.puts colorize("#{failures.size} of #{checks.size} checks failed.", :bold, :red)
      else
        @io.puts colorize("Environment ready ✔", :bold, :green)
      end
    end

    # -- table primitives --

    def border(left, mid, right, *widths)
      left + widths.map { |w| "─" * (w + 2) }.join(mid) + right
    end

    def header_row(name_w, status_w, detail_w)
      cells = [ cell(HEADERS[0], name_w, :bold), cell(HEADERS[1], status_w, :bold), cell(HEADERS[2], detail_w, :bold) ]
      "│ #{cells.join(' │ ')} │"
    end

    # Pad to the visible width first, THEN colour — the ANSI codes are zero-width,
    # so alignment is computed on the plain text and never drifts.
    def cell(text, width, *codes)
      colorize(text.to_s.ljust(width), *codes)
    end

    def blank(width) = " " * width

    def colorize(text, *codes)
      return text if !@color || codes.empty?

      "\e[#{codes.map { |c| SGR.fetch(c) }.join(';')}m#{text}\e[0m"
    end

    # -- helpers --

    def width_of(values, header)
      (values.map(&:length) + [ header.length ]).max
    end

    def terminal_width
      cols = (@io.winsize.last if @io.respond_to?(:winsize) && @io.tty?)
      cols || ENV["COLUMNS"]&.to_i.then { |c| c&.positive? ? c : nil } || 100
    rescue StandardError
      100
    end

    # Greedy word wrap to `width`, hard-breaking any token longer than the column.
    def wrap(text, width)
      words = text.to_s.split(/\s+/)
      lines = []
      cur = +""
      words.each do |word|
        while word.length > width
          lines << cur unless cur.empty?
          cur = +""
          lines << word[0, width]
          word = word[width..]
        end
        if cur.empty?
          cur = word.dup
        elsif cur.length + 1 + word.length <= width
          cur << " " << word
        else
          lines << cur
          cur = word.dup
        end
      end
      lines << cur unless cur.empty?
      lines.empty? ? [ "" ] : lines
    end
  end
end
