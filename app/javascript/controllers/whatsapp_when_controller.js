import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["always", "other"]

  connect() {
    this.sync()
  }

  sync() {
    const always = this.alwaysTarget.checked

    this.otherTargets.forEach((box) => {
      box.disabled = always
      if (always) box.checked = false
    })
  }
}
