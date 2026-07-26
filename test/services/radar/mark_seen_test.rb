require "test_helper"

# Clearing the Radar feed. The rules that matter: ops events never get marked
# (they close by resolving), an already-seen event keeps its original timestamp,
# and an event emitted after the sweep's clock stays unseen.
class Radar::MarkSeenTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 7, 15, 12, 0, 0)

  def event(category:, occurred_at: NOW - 1.hour, seen_at: nil)
    Event.create!(category: category, event_type: "outlier_crossed",
      occurred_at: occurred_at, seen_at: seen_at)
  end

  test "marks every unseen niche event up to now" do
    a = event(category: "niche")
    b = event(category: "niche", occurred_at: NOW - 3.days)

    assert_equal 2, Radar::MarkSeen.new(now: NOW).call
    assert_equal NOW, a.reload.seen_at
    assert_equal NOW, b.reload.seen_at
  end

  test "leaves ops events alone — they close by resolving, not by being looked at" do
    alert = event(category: "ops")

    assert_equal 0, Radar::MarkSeen.new(now: NOW).call
    assert_nil alert.reload.seen_at
  end

  test "does not restamp an event that was already seen" do
    earlier = NOW - 2.days
    seen = event(category: "niche", seen_at: earlier)

    Radar::MarkSeen.new(now: NOW).call

    assert_equal earlier, seen.reload.seen_at
  end

  test "an event emitted after the sweep's clock stays unseen" do
    later = event(category: "niche", occurred_at: NOW + 1.minute)

    assert_equal 0, Radar::MarkSeen.new(now: NOW).call
    assert_nil later.reload.seen_at
  end
end
