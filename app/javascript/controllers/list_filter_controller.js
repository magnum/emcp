import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["query", "item", "list", "empty"]

  filter() {
    const query = this.queryTarget.value.trim().toLowerCase()
    let shown = 0

    this.itemTargets.forEach((item) => {
      const haystack = (item.dataset.filterText || "").toLowerCase()
      const match = query === "" || haystack.includes(query)
      item.classList.toggle("hidden", !match)
      if (match) shown += 1
    })

    this.listTarget.classList.toggle("hidden", shown === 0)
    this.emptyTarget.classList.toggle("hidden", shown !== 0)
  }
}
