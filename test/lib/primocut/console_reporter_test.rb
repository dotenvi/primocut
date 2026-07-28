require "test_helper"
require Rails.root.join("lib/primocut/console_reporter")

# The terminal-facing reporter shared by the CLI's two long commands. Two output
# modes are covered: the live, self-redrawing line a real terminal gets, and the
# plain append-only lines everything else gets (a pipe, a redirect, CI, this
# suite). Both are exercised against a StringIO — no real tty, no network.
class Primocut::ConsoleReporterTest < ActiveSupport::TestCase
  # A StringIO that claims to be a terminal, so the live path is reachable
  # without one.
  class TtyIO < StringIO
    def tty? = true
  end

  ANSI = /\e\[/

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
