require "test_helper"

class Cuts::ManifestTest < ActiveSupport::TestCase
  Manifest = Cuts::Manifest

  Video = Struct.new(:youtube_id, :url, :title, :channel, :duration_s)
  Cut = Struct.new(:id, :name)

  def video = Video.new("abcdefghijk", "https://y/1", "Cool Live", "Cool Channel", 3600)
  def cut = Cut.new(7, "Best Of")

  def item(**over)
    { "position" => 1, "mp4" => "001-a.mp4", "srt" => "001-a.srt", "title" => "Opening",
      "kind" => "topic", "topic_id" => 3, "start_s" => 100.0, "end_s" => 130.0,
      "duration_s" => 30.0, "packaging" => { "titles" => [], "thumbnail_brief" => "" } }.merge(over)
  end

  test "data carries the source video, cut, master and items" do
    data = Manifest.data(video:, cut:, items: [ item ], master: nil, generated_at: "2026-07-25T00:00:00Z")
    assert_equal "abcdefghijk", data["live"]["video_id"]
    assert_equal 3600.0, data["live"]["duration_s"]
    assert_equal 7, data["cut"]["id"]
    assert_nil data["master"]
    assert_equal 1, data["items"].size
  end

  test "to_json_text round-trips" do
    data = Manifest.data(video:, cut:, items: [ item ], master: nil, generated_at: "t")
    assert_equal data, JSON.parse(Manifest.to_json_text(data))
  end

  test "markdown links each item timestamp back into the source video" do
    data = Manifest.data(video:, cut:, items: [ item ], master: nil, generated_at: "t")
    md = Manifest.to_markdown(data)
    assert_includes md, "# Cool Live — Best Of"
    assert_includes md, "https://www.youtube.com/watch?v=abcdefghijk&t=100"
    assert_includes md, "1:40" # 100s
    assert_includes md, "**Master**: skipped"
  end

  test "markdown renders the master line and a packaging section when present" do
    packaged = item("packaging" => { "titles" => [ "Title A", "Title B" ], "thumbnail_brief" => "big face" })
    master = { "filename" => "master.mp4", "resolution" => "1440p" }
    md = Manifest.to_markdown(Manifest.data(video:, cut:, items: [ packaged ], master:, generated_at: "t"))
    assert_includes md, "`master.mp4` (1440p)"
    assert_includes md, "## Packaging"
    assert_includes md, "- Title A"
    assert_includes md, "**Thumbnail**: big face"
  end

  test "format_timestamp uses H:MM:SS past an hour, else M:SS" do
    assert_equal "0:05", Manifest.format_timestamp(5)
    assert_equal "1:40", Manifest.format_timestamp(100)
    assert_equal "1:02:03", Manifest.format_timestamp(3723)
  end
end
