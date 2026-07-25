require "test_helper"

# Tests for the chat replay adapter — both fetchers injected (no network, no
# binaries). Covers the primary/fallback ladder and both parsers. Ported from
# the PoC `tests/test_chat_downloader.py`.
class Adapters::ChatDownloaderTest < ActiveSupport::TestCase
  Chat = Adapters::ChatDownloader

  test "uses chat_downloader messages when present" do
    items = [
      { "time_in_seconds" => 12.0, "author" => { "name" => "Ana" }, "message" => "kkkk" },
      { "time_in_seconds" => nil, "author" => "Ghost", "message" => "off-timeline" }, # dropped
      { "time_in_seconds" => 65.5, "author" => "Bob", "message" => "top" }
    ]
    adapter = Chat.new(chat_json_fetcher: ->(_url) { items })
    messages = adapter.download("https://y/1")

    assert_equal 2, messages.size
    assert_equal 12.0, messages.first.offset_seconds
    assert_equal "Ana", messages.first.author
    assert_equal "top", messages.last.text
  end

  test "falls back to yt-dlp live_chat when the primary is empty" do
    line = {
      "replayChatItemAction" => {
        "videoOffsetTimeMsec" => "30000",
        "actions" => [
          { "addChatItemAction" => { "item" => { "liveChatTextMessageRenderer" => {
            "message" => { "runs" => [ { "text" => "he" }, { "text" => "llo" } ] },
            "authorName" => { "simpleText" => "Cé" }
          } } } }
        ]
      }
    }.to_json
    adapter = Chat.new(
      chat_json_fetcher: ->(_url) { [] },
      live_chat_lines_fetcher: ->(_url) { [ "", line, "not-json" ] }
    )
    messages = adapter.download("https://y/1")

    assert_equal 1, messages.size
    assert_in_delta 30.0, messages.first.offset_seconds, 0.001
    assert_equal "Cé", messages.first.author
    assert_equal "hello", messages.first.text
  end

  test "returns nil when both strategies yield nothing" do
    adapter = Chat.new(
      chat_json_fetcher: ->(_url) { [] },
      live_chat_lines_fetcher: ->(_url) { [] }
    )
    assert_nil adapter.download("https://y/1")
  end

  test "a failing primary fetcher degrades to the fallback, never raises" do
    adapter = Chat.new(
      chat_json_fetcher: ->(_url) { raise "network down" },
      live_chat_lines_fetcher: ->(_url) { [] }
    )
    assert_nil adapter.download("https://y/1")
  end
end
