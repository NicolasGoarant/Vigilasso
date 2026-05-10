import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "email", "submit", "error"]

  open() {
    this.modalTarget.classList.remove("hidden")
    this.emailTarget.focus()
  }

  close() {
    this.modalTarget.classList.add("hidden")
    this.errorTarget.classList.add("hidden")
  }

  async submit() {
    const email = this.emailTarget.value.trim()
    if (!email) {
      this.showError("Adresse email requise.")
      return
    }
    this.submitTarget.disabled = true
    this.submitTarget.textContent = "Envoi…"

    const url = this.submitTarget.dataset.url
    const token = this.submitTarget.dataset.token

    try {
      const formData = new FormData()
      formData.append("email", email)
      formData.append("authenticity_token", token)
      const response = await fetch(url, {
        method: "POST",
        body: formData,
        headers: { "Accept": "application/json" }
      })
      const payload = await response.json().catch(() => null)
      if (!response.ok || !payload || !payload.ok) {
        this.showError((payload && payload.error) || "Échec de l'envoi.")
        this.submitTarget.disabled = false
        this.submitTarget.textContent = "Envoyer le lien"
        return
      }
      window.location.reload()
    } catch (e) {
      this.showError("Connexion interrompue.")
      this.submitTarget.disabled = false
      this.submitTarget.textContent = "Envoyer le lien"
    }
  }

  showError(msg) {
    this.errorTarget.textContent = msg
    this.errorTarget.classList.remove("hidden")
  }
}
