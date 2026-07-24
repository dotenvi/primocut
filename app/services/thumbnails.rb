require "digest"
require "net/http"
require "uri"

# Thumbnail content hashing. The initial `thumbnail_hash` stored per video is the
# SHA-256 of the thumbnail image BYTES (not the URL), so a later snapshot can
# detect a packaging change even when YouTube keeps the same thumbnail URL. The
# byte fetcher is injectable so tests run without network. Hashing degrades to an
# empty string on any error (never crashes the backfill). Ported from the PoC
# `youtube/thumbnails.py`.
module Thumbnails
  module_function

  def fetch_bytes(url, timeout: 30.0)
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                    open_timeout: timeout, read_timeout: timeout) do |http|
      http.get(uri.request_uri).body
    end
  end

  # SHA-256 hex of the thumbnail image bytes; "" when absent or on error.
  def digest(url, fetcher: method(:fetch_bytes))
    return "" if url.nil? || url.empty?

    Digest::SHA256.hexdigest(fetcher.call(url))
  rescue StandardError => e
    # Degrade: a missing hash must not fail the backfill.
    Rails.logger.warn("Thumbnail hashing failed for #{url}: #{e.message}")
    ""
  end
end
