import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["overlay"]

  connect() {
    this.hideAfterNavigation = this.hideAfterNavigation.bind(this)
    document.addEventListener("turbo:load", this.hideAfterNavigation)
  }

  disconnect() {
    document.removeEventListener("turbo:load", this.hideAfterNavigation)
  }

  showIfLoading() {
    if (this.element.dataset.loading !== "true") return

    this.show()
    this.awaitingNavigation = true
  }

  hideAfterNavigation() {
    if (!this.awaitingNavigation) return

    this.hide()
    this.awaitingNavigation = false
  }

  show() {
    this.overlayTarget.classList.remove("hidden")
    this.overlayTarget.setAttribute("aria-hidden", "false")
  }

  hide() {
    this.overlayTarget.classList.add("hidden")
    this.overlayTarget.setAttribute("aria-hidden", "true")
  }
}
