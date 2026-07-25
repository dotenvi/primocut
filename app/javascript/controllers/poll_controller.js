import { Controller } from "@hotwired/stimulus"

// Reloads its own turbo-frame on an interval so an in-flight source video shows
// live progress. Attached only to active rows; when a poll returns the terminal
// row (no controller, no src) the frame stops reloading on its own. This is the
// §2.7 "Turbo Frames with refresh" step — moving to Turbo Streams later needs no
// change to the view, only a broadcast in the job.
export default class extends Controller {
  static values = { interval: { type: Number, default: 2000 } }

  connect() {
    this.timer = setInterval(() => this.element.reload(), this.intervalValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }
}
