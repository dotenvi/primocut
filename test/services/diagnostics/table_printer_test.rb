require "test_helper"

# The doctor's table renderer. Colour is forced off and the width is fixed, so the
# assertions are stable: box borders, status labels, detail wrapping, fix hints and
# the summary line. It returns whether the environment is healthy.
class Diagnostics::TablePrinterTest < ActiveSupport::TestCase
  def check(name:, ok:, detail:, fix: nil, warn: false)
    Diagnostics::Check.new(name:, ok:, detail:, fix:, warn:)
  end

  def render(checks, width: 80)
    io = StringIO.new
    healthy = Diagnostics::TablePrinter.new(io:, color: false, width:).call(checks)
    [ io.string, healthy ]
  end

  test "renders a bordered table with headers and status labels" do
    out, healthy = render([ check(name: "FFmpeg", ok: true, detail: "ffmpeg 7.1") ])
    assert healthy
    assert_match(/┌.*┬.*┐/, out)
    assert_match(/└.*┴.*┘/, out)
    assert_match(/Check.*Status.*Detail/, out)
    assert_match(/FFmpeg.*OK.*ffmpeg 7\.1/, out)
  end

  test "emits no ANSI escape codes when colour is off" do
    out, = render([ check(name: "FFmpeg", ok: true, detail: "ok") ])
    refute_includes out, "\e["
  end

  test "wraps a long detail across multiple lines inside the cell" do
    long = "a b c d e f g h i j k l m n o p q r s t u v w x y z " * 4
    out, = render([ check(name: "X", ok: false, detail: long) ], width: 60)
    body = out.lines.count { |l| l.start_with?("│") && !l.include?("Check") }
    assert_operator body, :>, 1, "expected the long detail to wrap onto extra rows"
  end

  test "a hard failure lists its fix and reports unhealthy" do
    out, healthy = render([ check(name: "yt-dlp", ok: false, detail: "not found", fix: "pipx install yt-dlp") ])
    refute healthy
    assert_match(/How to fix:/, out)
    assert_match(/yt-dlp: pipx install yt-dlp/, out)
    assert_match(/1 of 1 checks failed\./, out)
  end

  test "a warning never fails the run and prints a note" do
    out, healthy = render([ check(name: "NVENC", ok: true, detail: "no encoder", fix: "use libx264", warn: true) ])
    assert healthy
    assert_match(/note.*NVENC.*use libx264/, out)
    assert_match(/Environment ready/, out)
  end

  test "colour on wraps status labels in ANSI codes" do
    io = StringIO.new
    Diagnostics::TablePrinter.new(io:, color: true, width: 80).call([ check(name: "X", ok: true, detail: "ok") ])
    assert_includes io.string, "\e["
  end
end
