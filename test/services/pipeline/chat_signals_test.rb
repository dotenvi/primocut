require "test_helper"

# Tests for the pure chat-signal computation (density, laughs/emotes, z-score
# peaks). Ported from the PoC `tests/test_chat_signals.py`.
class Pipeline::ChatSignalsTest < ActiveSupport::TestCase
  Signals = Pipeline::ChatSignals
  Msg = Data.define(:offset_seconds, :text)

  test "empty input yields an empty signal" do
    signal = Signals.compute([])
    assert_empty signal.per_minute
    assert_empty signal.peaks
  end

  test "buckets by minute and counts laughs and emotes" do
    messages = [
      Msg.new(offset_seconds: 5, text: "kkkk"),      # minute 0, laugh
      Msg.new(offset_seconds: 30, text: "🔥 vamos"),  # minute 0, emote
      Msg.new(offset_seconds: 70, text: "normal")    # minute 1
    ]
    signal = Signals.compute(messages)

    assert_equal 2, signal.per_minute.size
    b0 = signal.per_minute[0]
    assert_equal 2, b0.msgs
    assert_equal 1, b0.laughs
    assert_equal 1, b0.emotes
    assert_equal 1, signal.per_minute[1].msgs
  end

  test "detects a peak minute by z-score" do
    # Nine quiet minutes (1 msg each) and one loud minute (20 msgs) → a clear peak.
    messages = []
    9.times { |m| messages << Msg.new(offset_seconds: m * 60 + 1, text: "hi") }
    20.times { |i| messages << Msg.new(offset_seconds: 9 * 60 + i, text: "hype") }

    signal = Signals.compute(messages, threshold: 2.0)

    assert_equal 1, signal.peaks.size
    peak = signal.peaks.first
    assert_equal 540.0, peak.ts # minute 9 → 540s
    assert_equal 20.0, peak.intensity
    assert peak.z >= 2.0
  end

  test "flat density produces no peaks" do
    messages = (0..5).map { |m| Msg.new(offset_seconds: m * 60 + 1, text: "hi") }
    assert_empty Signals.compute(messages).peaks
  end

  test "laugh and emote detection helpers" do
    assert Signals.laugh?("kkkkk")
    assert Signals.laugh?("hahaha")
    assert Signals.laugh?("rsrsrs")
    assert Signals.laugh?("huehue")
    assert_not Signals.laugh?("obrigado")
    assert_equal 2, Signals.count_emotes("🔥❤")
    assert_equal 0, Signals.count_emotes("sem emote")
  end
end
