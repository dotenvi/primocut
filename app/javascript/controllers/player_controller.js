import { Controller } from "@hotwired/stimulus"

// The embedded YouTube player. Loads the IFrame API once per page, replaces its
// own div with the iframe, and offers the three things the rest of the room needs
// from it: seek, pause, and where it currently is.
//
// A timestamp reaches it through a `player:seek` window event rather than a
// reference, so a line anywhere on the screen can drive it without knowing where
// the player is or whether it has finished loading.
export default class extends Controller {
  static values = { videoId: String }

  connect() {
    this.constructor.api().then((YT) => {
      if (!this.element.isConnected) return
      this.player = new YT.Player(this.element.querySelector("[data-player-mount]"), {
        videoId: this.videoIdValue,
        playerVars: { rel: 0, modestbranding: 1 },
      })
    })
  }

  disconnect() {
    this.player?.destroy?.()
    this.player = null
  }

  // Announced from anywhere via `player:seek`. Scrolling back matters: a timestamp
  // clicked far down the transcript would otherwise move a video nobody can see.
  seek(event) {
    const seconds = Number(event.detail?.seconds)
    if (Number.isNaN(seconds)) return
    this.seekTo(seconds)
    this.element.scrollIntoView({ behavior: "smooth", block: "start" })
  }

  seekTo(seconds) {
    this.player?.seekTo?.(seconds, true)
    this.player?.playVideo?.()
  }

  pause() { this.player?.pauseVideo?.() }

  currentTime() { return this.player?.getCurrentTime?.() ?? 0 }

  // One API load per page, shared by every player on it.
  static api() {
    if (this.apiPromise) return this.apiPromise
    this.apiPromise = new Promise((resolve) => {
      if (window.YT?.Player) return resolve(window.YT)
      window.onYouTubeIframeAPIReady = () => resolve(window.YT)
      const tag = document.createElement("script")
      tag.src = "https://www.youtube.com/iframe_api"
      document.head.appendChild(tag)
    })
    return this.apiPromise
  }
}
