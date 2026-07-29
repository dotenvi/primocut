require "test_helper"

class Http::ByteRangeTest < ActiveSupport::TestCase
  test "an explicit range is served as asked" do
    assert_equal 2..5, Http::ByteRange.parse("bytes=2-5", size: 11)
  end

  # What a browser actually sends when it opens a video. Answering it whole would
  # pull the entire master into memory, so it is capped at a chunk.
  test "an open-ended range is capped at the chunk size" do
    assert_equal 0..3, Http::ByteRange.parse("bytes=0-", size: 1_000, chunk: 4)
  end

  test "a range past the end of the file stops at the last byte" do
    assert_equal 8..10, Http::ByteRange.parse("bytes=8-99", size: 11)
  end

  # nil means "answer with the whole file" — always a valid reply to a range
  # request, and the one the caller already knows how to send.
  test "no header, a malformed one, or a start past the end asks for the whole file" do
    assert_nil Http::ByteRange.parse(nil, size: 11)
    assert_nil Http::ByteRange.parse("bytes=abc", size: 11)
    assert_nil Http::ByteRange.parse("bytes=0-5, 8-9", size: 11)
    assert_nil Http::ByteRange.parse("bytes=-500", size: 11)
    assert_nil Http::ByteRange.parse("bytes=11-20", size: 11)
  end
end
