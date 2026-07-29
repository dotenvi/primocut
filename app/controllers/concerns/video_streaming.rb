# Handing a video file to a browser, byte ranges and all.
#
# Nothing here knows what a cut is: this is transport, and it changes when the way
# the app serves bytes changes — never when the room it is played in changes. That
# is why it does not live in the room's controller.
module VideoStreaming
  extend ActiveSupport::Concern

  private

  # `send_file` answers the whole file, so a ranged request is served by hand
  # instead — the seek bar depends on it.
  def stream_video(path)
    size = File.size(path)
    response.headers["Accept-Ranges"] = "bytes"
    range = Http::ByteRange.parse(request.headers["Range"], size: size)
    return send_file(path, type: "video/mp4", disposition: "inline") unless range

    response.headers["Content-Range"] = "bytes #{range.begin}-#{range.end}/#{size}"
    send_data File.binread(path, range.size, range.begin),
      type: "video/mp4", disposition: "inline", status: :partial_content
  end
end
