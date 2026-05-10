import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "input", "filename", "submit", "overlay", "step", "error"]

  preview() {
    const file = this.inputTarget.files[0]
    if (!file) return
    this.filenameTarget.textContent = `Fichier sélectionné : ${file.name} (${Math.round(file.size / 1024)} Ko)`
    this.filenameTarget.classList.remove("hidden")
  }

  async start(event) {
    event.preventDefault()

    const file = this.inputTarget.files[0]
    if (!file) return

    this.errorTarget.classList.add("hidden")
    this.formTarget.classList.add("hidden")
    this.overlayTarget.classList.remove("hidden")
    this.overlayTarget.scrollIntoView({ behavior: "smooth", block: "center" })
    this.submitTarget.disabled = true

    const sequence = [
      { step: "read",    delay: 0 },
      { step: "extract", delay: 1500 },
      { step: "ratios",  delay: 3000 },
      { step: "score",   delay: 4400 }
    ]
    sequence.forEach(({ step, delay }) => setTimeout(() => this.activateStep(step), delay))

    const startedAt = Date.now()
    const minDuration = 5200

    const formData = new FormData()
    formData.append("pdf", file)
    formData.append("authenticity_token", this.formTarget.querySelector('[name="authenticity_token"]').value)

    let payload = null
    let errorMsg = null
    try {
      const response = await fetch(this.formTarget.action, {
        method: "POST",
        body: formData,
        headers: { "Accept": "application/json" }
      })
      payload = await response.json().catch(() => null)
      if (!response.ok) {
        errorMsg = (payload && payload.error) || `Erreur serveur (${response.status}).`
      }
    } catch (e) {
      errorMsg = "Connexion interrompue. Réessayez."
    }

    const elapsed = Date.now() - startedAt
    if (elapsed < minDuration) {
      await new Promise((r) => setTimeout(r, minDuration - elapsed))
    }

    if (errorMsg) {
      this.completeAllSteps()
      this.overlayTarget.classList.add("hidden")
      this.formTarget.classList.remove("hidden")
      this.submitTarget.disabled = false
      this.errorTarget.textContent = errorMsg
      this.errorTarget.classList.remove("hidden")
      return
    }

    this.completeAllSteps()
    window.location.href = payload.redirect || `/analyse/${payload.token}`
  }

  activateStep(stepKey) {
    const items = this.stepTargets
    const idx = items.findIndex((el) => el.dataset.step === stepKey)
    if (idx < 0) return
    items.forEach((el, i) => {
      const dot = el.querySelector(".dot")
      const check = el.querySelector(".check")
      const label = el.querySelector(".step-label")
      const icon = el.querySelector(".step-icon")

      if (i < idx) {
        el.classList.remove("text-slate-400", "text-white")
        el.classList.add("text-slate-300")
        dot.classList.add("hidden")
        check.classList.remove("hidden")
        icon.classList.remove("border-slate-700", "bg-slate-800/50", "border-indigo-400")
        icon.classList.add("bg-emerald-500", "border-emerald-500")
        label.classList.remove("font-semibold")
      } else if (i === idx) {
        el.classList.remove("text-slate-400")
        el.classList.add("text-white")
        dot.classList.remove("hidden")
        dot.classList.remove("bg-slate-600")
        dot.classList.add("bg-indigo-400", "animate-pulse")
        check.classList.add("hidden")
        icon.classList.remove("border-slate-700", "bg-slate-800/50", "bg-emerald-500", "border-emerald-500")
        icon.classList.add("border-indigo-400", "bg-indigo-500/20")
        label.classList.add("font-semibold")
      }
    })
  }

  completeAllSteps() {
    this.stepTargets.forEach((el) => {
      const dot = el.querySelector(".dot")
      const check = el.querySelector(".check")
      const icon = el.querySelector(".step-icon")
      dot.classList.add("hidden")
      check.classList.remove("hidden")
      icon.classList.remove("border-slate-700", "bg-slate-800/50", "border-indigo-400", "bg-indigo-500/20")
      icon.classList.add("bg-emerald-500", "border-emerald-500")
      el.classList.remove("text-slate-400")
      el.classList.add("text-slate-300")
    })
  }
}
