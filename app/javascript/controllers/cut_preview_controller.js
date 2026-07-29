import { Controller } from "@hotwired/stimulus"

// Switches the stage between SOURCE (the YouTube video and its transcript) and CUT
// (the composition itself).
//
// CUT plays the concatenated master: one file, so playback is seamless and the
// browser can scrub across the whole composition. There is nothing to drive — the
// <video> does the playing. What is left is switching modes, jumping to an item's
// offset inside the file, and showing which item is on screen.
//
// (Two earlier versions did more and were worse: one seeked the YouTube player
// across the source, which lands on keyframes rather than cut points; one chained
// the clip files, which paid a file load at every item boundary.)
export default class extends Controller {
  static targets = ["mode", "panel", "segment", "video", "toggle", "status"]
  static outlets = ["player"]
  static values = { mode: { type: String, default: "source" } }

  show(event) { this.modeValue = event.params.mode }

  // A timestamp anywhere in the room — a topic's range, an item's title — seeks the
  // SOURCE player, so the stage has to be showing it. Clicked while the rendered cut
  // is on screen, it would otherwise move a video nobody can see.
  source() { this.modeValue = "source" }

  // Stimulus calls this on every change, including the initial render.
  modeValueChanged() {
    // Only one thing may be making sound.
    if (this.modeValue !== "source") this.playerOutlet?.pause()
    if (this.modeValue !== "cut" && this.hasVideoTarget) this.videoTarget.pause()
    this.sync()
  }

  // A finishing render streams in a new mode switcher and a playback panel that did
  // not exist before. Which mode is active is applied HERE, not by the server, so it
  // has to be re-applied to whatever just arrived — otherwise the freshly replaced
  // switcher shows no active mode and every panel comes back visible at once.
  modeTargetConnected() { this.sync() }
  panelTargetConnected() { this.sync() }

  sync() {
    this.modeTargets.forEach((el) => el.classList.toggle("on", el.dataset.mode === this.modeValue))
    this.panelTargets.forEach((el) => { el.hidden = el.dataset.mode !== this.modeValue })
  }

  toggle() {
    if (!this.hasVideoTarget) return

    this.videoTarget.paused ? this.videoTarget.play()?.catch?.(() => {}) : this.videoTarget.pause()
  }

  // Seek to where this item begins inside the master.
  jump(event) {
    const segment = this.segmentTargets[Number(event.params.index)]
    if (!segment || !this.hasVideoTarget) return

    this.videoTarget.currentTime = Number(segment.dataset.at)
    this.videoTarget.play()?.catch?.(() => {})
  }

  // Driven by the <video>'s own timeupdate, so dragging its scrub bar moves the
  // marked segment too — the strip reflects the file rather than commanding it.
  track() {
    if (!this.hasVideoTarget) return

    const at = this.videoTarget.currentTime
    const index = this.segmentTargets.findIndex(
      (el) => at >= Number(el.dataset.at) && at < Number(el.dataset.until)
    )
    if (index === -1 || index === this.current) return

    this.current = index
    this.mark()
  }

  mark() {
    this.segmentTargets.forEach((el, i) => el.classList.toggle("on", i === this.current))
    const segment = this.segmentTargets[this.current]
    if (this.hasStatusTarget && segment) {
      this.statusTarget.textContent =
        `item ${this.current + 1} of ${this.segmentTargets.length} · ${segment.dataset.title}`
    }
  }

  label() {
    if (!this.hasToggleTarget) return

    this.toggleTarget.textContent = this.videoTarget?.paused === false ? "❚❚ Pause" : "▶ Play cut"
  }
}
