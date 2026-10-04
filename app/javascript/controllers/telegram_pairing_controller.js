import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["hint", "error"]
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

      this.apply(await response.json())
    } catch (_error) {
      // keep the last painted state
    }
  }

  apply(data) {
    if (data.authenticated) {
      window.location.reload()
      return
    }

    if (this.hasHintTarget) {
      if (data.auth_step === "code") {
        this.hintTarget.textContent = "Telegram sent a login code. Enter it below and click Submit code."
      } else if (data.auth_step === "password") {
        this.hintTarget.textContent = "This account has a cloud password. Enter it below and click Submit password."
      }
    }

    if (this.hasErrorTarget) {
      const message = data.error || ""
      this.errorTarget.textContent = message
      this.errorTarget.classList.toggle("hidden", !message)
    }
  }
}
