require "test_helper"
require Rails.root.join("lib/primocut/console_reporter")

# The terminal-facing reporter shared by the CLI's two long commands. Two output
# modes are covered: the live, self-redrawing line a real terminal gets, and the
# plain append-only lines everything else gets (a pipe, a redirect, CI, this
# suite). Both are exercised against a StringIO — no real tty, no network.
class Primocut::ConsoleReporterTest < ActiveSupport::TestCase
  # A StringIO that claims to be a terminal of a given width, so the live path is
  # reachable without one. The width is not a detail: a line wider than the
  # terminal wraps, and `\e[2K\r` then clears only the last physical line — every
  # frame leaves its overflow on screen forever.
  class TtyIO < StringIO
    attr_accessor :columns # writable: a terminal can be resized mid-run

    def initialize(columns: 80)
      super()
      @columns = columns
    end

    def tty? = true
    def winsize = [ 24, @columns ]
  end

  ANSI = /\e\[/

  def frames(io) = io.string.split("\e[2K\r").reject(&:empty?)

  def visible_widths(io) = frames(io).map { |f| f.gsub(/\e\[[0-9;]*m/, "").chomp.length }

  # ------------------------- non-tty (pipe, CI, tests) -------------------------

  test "non-tty prints one plain line per stage and nothing for detail churn" do
    io = StringIO.new
    reporter = Primocut::ConsoleReporter.new(io:)

    reporter.update(stage: "Channels", progress: 0, detail: "0/2")
    reporter.update(stage: "Channels", progress: 12, detail: "1/2 · thumbs 3/9")
    reporter.update(stage: "Comments", progress: 94)
    reporter.close

    lines = io.string.lines.map(&:chomp)
    assert_equal 2, lines.size, "a detail-only update must not print a second line"
    assert_match(/Channels/, lines[0])
    assert_match(/Comments/, lines[1])
  end

  test "non-tty output carries no escape codes and never redraws" do
    io = StringIO.new
    reporter = Primocut::ConsoleReporter.new(io:)

    reporter.update(stage: "Channels", progress: 10, detail: "1/1")
    reporter.warn("channel UC_x failed: boom")
    reporter.close

    refute_match(ANSI, io.string)
    refute_includes io.string, "\r"
  end

  # ------------------------- live terminal -------------------------

  test "live mode redraws in place and settles each finished stage" do
    io = TtyIO.new
    reporter = Primocut::ConsoleReporter.new(io:)

    reporter.update(stage: "Channels", progress: 10, detail: "1/2")
    reporter.update(stage: "Comments", progress: 94)
    reporter.close

    out = io.string
    assert_includes out, "\e[2K\r", "the live line must be cleared and rewritten in place"
    assert_equal 2, out.scan("✓").size, "each stage settles into one permanent line"
    assert_includes out, "Channels"
    assert_includes out, "Comments"
  end

  test "live mode draws a bar whose fill tracks progress" do
    io = TtyIO.new
    reporter = Primocut::ConsoleReporter.new(io:)

    reporter.update(stage: "Channels", progress: 0)
    empty = io.string.scan("█").size
    reporter.update(stage: "Channels", progress: 50)
    reporter.close

    assert_equal 0, empty
    assert_operator io.string.scan("█").size, :>, 0
  end

  # ------------------------- fitting the terminal -------------------------

  test "no line ever exceeds the terminal width" do
    io = TtyIO.new(columns: 60)
    reporter = Primocut::ConsoleReporter.new(io:)

    reporter.update(stage: "Channels", progress: 4, detail: "1/3 @felipeneto · thumbs 5/15 · 87 quota")
    reporter.update(stage: "Metrics artifacts", progress: 80, detail: "1204 quota")
    reporter.close

    assert_operator visible_widths(io).max, :<, 60,
                    "a line wider than the terminal wraps, and a wrapped line defeats the in-place redraw"
  end

  test "a narrow terminal trims the detail and keeps the stage, the meter and the clock" do
    io = TtyIO.new(columns: 60)
    reporter = Primocut::ConsoleReporter.new(io:)

    reporter.update(stage: "Channels", progress: 4, detail: "1/3 @felipeneto · thumbs 5/15 · 87 quota")
    reporter.close

    live = frames(io).first
    assert_includes live, "…", "a trimmed detail must not read as a complete one"
    assert_includes live, "Channels"
    assert_match(/\d+%/, live)
    assert_match(/\d\.\ds/, live) # the clock is never what gives way
  end

  test "a narrow terminal spends its columns on the sub-step, not on the bar" do
    io = TtyIO.new(columns: 55)
    reporter = Primocut::ConsoleReporter.new(io:)

    reporter.update(stage: "Channels", progress: 4, detail: "1/3 @felipeneto · thumbs 5/15 · 87 quota")
    reporter.close

    live = frames(io).first
    assert_operator visible_widths(io).max, :<, 55
    refute_includes live, "░", "the bar is not worth the columns the sub-step needs"
    assert_includes live, "thumbs", "the sub-step is the whole point of the line"
  end

  test "a terminal too narrow for the bar still reports one truthful line" do
    io = TtyIO.new(columns: 20)
    reporter = Primocut::ConsoleReporter.new(io:)

    reporter.update(stage: "Channels", progress: 4, detail: "1/3 @felipeneto")
    reporter.close

    assert_operator visible_widths(io).max, :<, 20
    assert_includes frames(io).first, "Chan"
  end

  # ------------------------- resize mid-run -------------------------

  test "narrowing the terminal wipes the rows the drawn line reflowed into" do
    io = TtyIO.new(columns: 120)
    reporter = Primocut::ConsoleReporter.new(io:)
    reporter.update(stage: "Channels", progress: 38, detail: "2/3 @inevitavelcortes · thumbs 7/15 · 214 quota")

    io.columns = 55 # the window moved back to the narrower screen
    reporter.update(stage: "Channels", progress: 42, detail: "2/3 @inevitavelcortes · thumbs 8/15 · 214 quota")
    reporter.close

    assert_includes io.string, "\e[1A",
                    "a reflowed row a single clear cannot reach must be wiped, not left on screen"
  end

  test "every line still fits after a resize, in both directions" do
    io = TtyIO.new(columns: 60)
    reporter = Primocut::ConsoleReporter.new(io:)
    reporter.update(stage: "Channels", progress: 38, detail: "2/3 @inevitavelcortes · thumbs 7/15 · 214 quota")

    io.columns = 130
    reporter.update(stage: "Channels", progress: 42, detail: "2/3 @inevitavelcortes · thumbs 8/15 · 214 quota")
    wide = visible_widths(io).max

    io.columns = 45
    reporter.update(stage: "Comments", progress: 94, detail: "214 quota")
    reporter.close

    assert_operator wide, :<, 130
    assert_operator frames(io).last.gsub(/\e\[[0-9;]*m/, "").chomp.length, :<, 45
  end

  # ------------------------- the two reporter contracts -------------------------

  test "update accepts the pipeline runner's video_status without raising" do
    io = StringIO.new
    reporter = Primocut::ConsoleReporter.new(io:)

    reporter.update(stage: "Audio download", progress: 15, video_status: :downloading)
    reporter.close

    assert_match(/Audio download/, io.string)
  end

  test "warn surfaces a failure the log alone would swallow" do
    io = StringIO.new
    reporter = Primocut::ConsoleReporter.new(io:)

    reporter.update(stage: "Channels", progress: 0)
    reporter.warn("channel UC_x failed: boom")
    reporter.close

    assert_match(/channel UC_x failed: boom/, io.string)
  end

  # ------------------------- lifecycle -------------------------

  test "close is idempotent, stops reporting and leaves no ticker writing" do
    io = TtyIO.new
    reporter = Primocut::ConsoleReporter.new(io:)
    reporter.update(stage: "Channels", progress: 0)

    reporter.close
    settled = io.string.length
    reporter.close
    reporter.update(stage: "Comments", progress: 94)
    sleep 0.25 # long enough for a surviving ticker thread to redraw

    assert_equal settled, io.string.length
  end
end
