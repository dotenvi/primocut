module Http
  # A `Range` request header, resolved against the size of the file it asks for.
  #
  # Range requests are the difference between a player that can scrub and one that
  # downloads half a gigabyte before showing a frame. The open-ended form a browser
  # actually sends — "bytes=0-" — is capped at CHUNK rather than answered whole,
  # because serving it whole would pull the entire master into memory.
  #
  # Only the single-range form is understood. Anything else — several ranges, a
  # suffix range, a malformed header, a start past the end of the file — resolves
  # to nil, which means "answer with the whole file": always a valid reply to a
  # range request, and the one the caller already knows how to send.
  module ByteRange
    module_function

    CHUNK = 8.megabytes

    # The byte range to serve, or nil when the header asks for nothing this
    # understands.
    def parse(header, size:, chunk: CHUNK)
      match = header.to_s.match(/\Abytes=(\d+)-(\d*)\z/) or return nil

      from = match[1].to_i
      last = match[2].presence&.to_i || (from + chunk - 1)
      last = [ last, size - 1 ].min
      from <= last ? (from..last) : nil
    end
  end
end
