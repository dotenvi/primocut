import { Controller } from "@hotwired/stimulus"

// Rows that keep their detail folded away until it is asked for. A trigger and its
// detail are paired by `data-key`, so one controller serves a whole list.
//
// Which rows are open is held HERE rather than on the elements, because the list
// they live in is replaced wholesale: adding a topic to the cut re-renders the
// entire bench, and state written on those elements would be thrown away with them.
// This controller is mounted OUTSIDE the frame that gets replaced, so a row that
// arrives open is restored as it connects.
export default class extends Controller {
  static targets = ["trigger", "detail"]

  initialize() { this.open = new Set() }

  toggle(event) {
    const key = event.currentTarget.dataset.key
    this.open.has(key) ? this.open.delete(key) : this.open.add(key)
    this.apply()
  }

  triggerTargetConnected() { this.apply() }
  detailTargetConnected() { this.apply() }

  apply() {
    this.detailTargets.forEach((el) => { el.hidden = !this.open.has(el.dataset.key) })
    this.triggerTargets.forEach((el) =>
      el.setAttribute("aria-expanded", String(this.open.has(el.dataset.key)))
    )
  }
}
