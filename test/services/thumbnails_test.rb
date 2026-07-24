require "test_helper"

# Tests for thumbnail content hashing (fetcher injected, no network). Ported from
# the PoC `tests/test_thumbnails.py` behaviour.
class ThumbnailsTest < ActiveSupport::TestCase
  test "empty url hashes to empty string" do
    assert_equal "", Thumbnails.digest("", fetcher: ->(_url) { raise "unreachable" })
    assert_equal "", Thumbnails.digest(nil, fetcher: ->(_url) { raise "unreachable" })
  end

  test "hashes the fetched image bytes with sha256" do
    bytes = "\x89PNG binary body"
    digest = Thumbnails.digest("https://img/x.jpg", fetcher: ->(_url) { bytes })
    assert_equal Digest::SHA256.hexdigest(bytes), digest
  end

  test "degrades to empty string on fetch error" do
    digest = Thumbnails.digest("https://img/x.jpg", fetcher: ->(_url) { raise SocketError, "down" })
    assert_equal "", digest
  end
end
