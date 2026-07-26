require "test_helper"

# The YouTube quota accounting. The `since` bound is what makes the sidebar's
# reading meaningful — the API budget resets daily, so an all-time total read
# against a daily cap would creep towards "exceeded" forever.
class Activity::QuotaUsedTest < ActiveSupport::TestCase
  def cycle(units:, occurred_at: 1.hour.ago, type: "cycle_done")
    Event.create!(category: "ops", event_type: type, occurred_at: occurred_at,
      payload: { "quota_units" => units })
  end

  test "sums the units the cycles accounted for" do
    cycle(units: 11)
    cycle(units: 9)

    assert_equal 20, Activity::QuotaUsed.new.call
  end

  test "counts only cycle events, whatever else carries the key" do
    cycle(units: 11)
    cycle(units: 999, type: "outlier_crossed")

    assert_equal 11, Activity::QuotaUsed.new.call
  end

  test "a since bound excludes what happened before it" do
    cycle(units: 11, occurred_at: 2.days.ago)
    cycle(units: 9, occurred_at: 10.minutes.ago)

    assert_equal 9, Activity::QuotaUsed.new(since: Time.current.beginning_of_day).call
  end

  test "a cycle that recorded no units counts as zero, not nil" do
    Event.create!(category: "ops", event_type: "cycle_done", occurred_at: 1.hour.ago, payload: {})

    assert_equal 0, Activity::QuotaUsed.new.call
  end

  test "nothing recorded reads as zero" do
    assert_equal 0, Activity::QuotaUsed.new.call
  end
end
