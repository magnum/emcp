import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["qr", "hint", "state"]
  static values = { url: String }

  connect() {
    this.timer = window.setInterval(() => this.poll(), 3000)
  }

  disconnect() {
    if (this.timer) window.clearInterval(this.timer)
  }

  async poll() {
    if (!this.urlValue) return

    try {
      const url = new URL(this.urlValue, window.location.origin)
      url.searchParams.set("refresh", "1")
      const response = await fetch(url.toString(), {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      })
      if (!response.ok) return

      const data = await response.json()
      if (data.connected) {
        window.location.reload()
        return
      }
      if (this.hasQrTarget && data.qr_png_base64) {
        this.qrTarget.src = `data:image/png;base64,${data.qr_png_base64}`
        this.qrTarget.classList.remove("hidden")
      }
      if (this.hasHintTarget && data.qr_png_base64) {
        this.hintTarget.textContent = "Scan this QR from the extension popup, or paste the payload below."
      }
      if (this.hasStateTarget) {
        this.stateTarget.textContent = data.connected ? "Extension online" : "Paired, extension offline"
      }
    } catch (_error) {
      // keep the last painted state
    }
  }
}
