import { Controller } from "@hotwired/stimulus"

// Polls a URL for Turbo Streams while background work runs.
//
// The sibling `poll` controller reloads its own turbo-frame, which is enough when
// everything that changes lives inside that frame. It is not enough for a render:
// finishing also enables the stage's mode switcher and brings the preview panel into
// existence, both outside the frame. Streams address elements by id, so one response
// updates all of them — with no page visit and no frame navigation.
//
// Self-terminating: this element is rendered only while the work is in flight, so
// the response that reports it settled replaces this controller away.
export default class extends Controller {
  static values = {
    url: String,
    interval: { type: Number, default: 2000 }
  }

  connect() {
    this.timer = setInterval(() => this.tick(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
    this.timer = null
  }

  async tick() {
    // Skip rather than queue: a slow response must not stack up requests behind it.
    if (this.fetching) return

    this.fetching = true
    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "text/vnd.turbo-stream.html" },
        credentials: "same-origin"
      })
      if (!response.ok) return

      window.Turbo?.renderStreamMessage(await response.text())
    } catch {
      // A dropped poll is not worth surfacing — the next tick tries again, and the
      // work itself is unaffected by our failure to look at it.
    } finally {
      this.fetching = false
    }
  }
}
