import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["source", "button"]
  static values = { copiedLabel: { type: String, default: "Copied" } }

  copy() {
    const value = this.sourceTarget.value || this.sourceTarget.textContent
    if (!value) return

    navigator.clipboard.writeText(value.trim()).then(() => {
      if (!this.hasButtonTarget) return

      const button = this.buttonTarget
      const originalLabel = button.getAttribute("aria-label")
      const originalTitle = button.getAttribute("title")
      button.setAttribute("aria-label", this.copiedLabelValue)
      button.setAttribute("title", this.copiedLabelValue)

      const originalText = button.childElementCount === 0 ? button.textContent : null
      if (originalText !== null) button.textContent = this.copiedLabelValue

      window.setTimeout(() => {
        if (originalText !== null) button.textContent = originalText
        if (originalLabel) {
          button.setAttribute("aria-label", originalLabel)
        } else {
          button.removeAttribute("aria-label")
        }
        if (originalTitle) {
          button.setAttribute("title", originalTitle)
        } else {
          button.removeAttribute("title")
        }
      }, 1500)
    })
  }

  selectAll() {
    if (this.sourceTarget.select) this.sourceTarget.select()
  }
}
