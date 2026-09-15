import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["qr", "hint", "error"]
  static values = { url: String }

  connect() {
    this.poll = this.poll.bind(this)
    this.timer = window.setInterval(this.poll, 2000)
    this.poll()
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
      this.apply(data)
    } catch (_error) {
      // keep last painted state
    }
  }

  apply(data) {
    if (data.authenticated) {
      window.location.reload()
      return
    }

    if (this.hasQrTarget && data.qr_png_base64) {
      this.qrTarget.src = `data:image/png;base64,${data.qr_png_base64}`
      this.qrTarget.classList.remove("hidden")
    }

    if (this.hasHintTarget) {
      if (data.qr_png_base64 || data.qr) {
        this.hintTarget.textContent = "Scan this code in WhatsApp → Linked devices. It refreshes automatically."
      } else if (data.pairing) {
        this.hintTarget.textContent = "Waiting for a QR code from the WhatsApp bridge…"
      }
    }

    if (this.hasErrorTarget) {
      const message = data.error || ""
      this.errorTarget.textContent = message
      this.errorTarget.classList.toggle("hidden", !message)
    }
  }
}
