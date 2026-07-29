import { Controller } from "@hotwired/stimulus"

// A clickable timestamp. Announces the seek to the player rather than reaching
// for it, so a timestamp works from anywhere on the screen without knowing where
// the player is or whether it has loaded yet.
export default class extends Controller {
  static values = { seconds: Number }

  seek(event) {
    event.preventDefault()
    window.dispatchEvent(new CustomEvent("player:seek", { detail: { seconds: this.secondsValue } }))
  }
}
