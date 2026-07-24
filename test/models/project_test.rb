require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  test "name is required and unique" do
    Project.create!(name: "Nicho A")
    dup = Project.new(name: "Nicho A")
    assert_not dup.valid?
  end

  test "competitor_channels through project_channels" do
    p = Project.create!(name: "Nicho B")
    c = CompetitorChannel.create!(youtube_channel_id: "UC_b")
    p.project_channels.create!(competitor_channel: c)
    assert_includes p.competitor_channels, c
  end

  test "destroying a project detaches channels but never deletes channel data" do
    p = Project.create!(name: "Nicho C")
    c = CompetitorChannel.create!(youtube_channel_id: "UC_c")
    p.project_channels.create!(competitor_channel: c)

    p.destroy

    assert_empty ProjectChannel.where(competitor_channel_id: c.id)
    assert CompetitorChannel.exists?(c.id), "channel survives project deletion"
  end
end
