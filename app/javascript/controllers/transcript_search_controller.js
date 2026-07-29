import { Controller } from "@hotwired/stimulus"

// Filters the transcript in place. The segments are already in the DOM — a
// thousand-odd of them — so searching is a matter of hiding what does not match,
// never a request: a round-trip per keystroke would make reading it unusable.
//
// The text of each line is read once on connect rather than on every keystroke,
// so typing stays cheap however long the transcript is.
export default class extends Controller {
  static targets = ["segment", "query", "empty", "term"]

  connect() {
    this.haystack = this.segmentTargets.map((el) => el.textContent.toLowerCase())
  }

  filter() {
    const query = this.queryTarget.value.trim().toLowerCase()
    let matches = 0

    this.segmentTargets.forEach((segment, i) => {
      const hit = query === "" || this.haystack[i].includes(query)
      segment.hidden = !hit
      if (hit) matches++
    })

    this.termTarget.textContent = this.queryTarget.value.trim()
    this.emptyTarget.hidden = matches > 0 || query === ""
  }
}
