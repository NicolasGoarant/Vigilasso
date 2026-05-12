import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu", "iconOpen", "iconClose"]

  toggle() {
    this.menuTarget.classList.toggle("hidden")
    this.iconOpenTarget.classList.toggle("hidden")
    this.iconCloseTarget.classList.toggle("hidden")
  }
}
