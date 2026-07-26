require "test_helper"

# The activity log's cursor and its quota accounting. The cursor is by descending
# id, not offset: the log grows at the head, so an offset page would shift under
# a reader between requests and silently skip rows.
class Activity::LogTest < ActiveSupport::TestCase
  def event(occurred_at: 1.hour.ago, type: "cycle_done", payload: {})
    Event.create!(category: "ops", event_type: type, occurred_at: occurred_at, payload: payload)
  end

  test "returns the newest events first" do
    old = event(occurred_at: 2.days.ago)
    recent = event(occurred_at: 1.minute.ago)

    assert_equal [ recent.id, old.id ], Activity::Log.new.call.rows.map(&:id)
  end

  test "the cursor takes only what is strictly older" do
    older = event(occurred_at: 2.hours.ago)   # appended first, so the lower id
    newest = event(occurred_at: 1.minute.ago)

    rows = Activity::Log.new(before_id: newest.id).call.rows

    assert_equal [ older.id ], rows.map(&:id)
  end

  test "the cursor walks append order, not occurred_at" do
    # Two events can share an occurred_at, and one can be recorded late, so the
    # cursor rides the id — the only strictly increasing, unique column.
    first = event(occurred_at: 1.minute.ago)
    backfilled = event(occurred_at: 10.days.ago)

    assert_equal [ backfilled.id, first.id ], Activity::Log.new.call.rows.map(&:id)
    assert_empty Activity::Log.new(before_id: first.id).call.rows
  end

  test "offers a cursor only while there is more behind it" do
    5.times { |i| event(occurred_at: (i + 1).hours.ago) }

    first = Activity::Log.new(limit: 2).call
    assert_not_nil first.next_before_id

    last = Activity::Log.new(before_id: first.next_before_id, limit: 10).call
    assert_nil last.next_before_id, "a partial page is the end of the log"
  end

  test "a full page that happens to end the log offers no cursor" do
    2.times { |i| event(occurred_at: (i + 1).hours.ago) }

    assert_nil Activity::Log.new(limit: 2).call.next_before_id
  end

  test "sums the quota across cycle events only" do
    event(payload: { "quota_units" => 11 })
    event(payload: { "quota_units" => 9 })
    event(type: "outlier_crossed", payload: { "quota_units" => 999 })
    event(payload: {}) # a cycle that recorded none

    assert_equal 20, Activity::Log.new.call.quota_units
  end

  test "the quota is zero, not nil, before anything has run" do
    assert_equal 0, Activity::Log.new.call.quota_units
  end

  test "a blank cursor reads as no cursor" do
    newest = event(occurred_at: 1.minute.ago)

    assert_equal [ newest.id ], Activity::Log.new(before_id: "").call.rows.map(&:id)
  end
end
