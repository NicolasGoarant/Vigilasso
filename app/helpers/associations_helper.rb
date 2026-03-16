module AssociationsHelper
  NIVEAU_STYLES = {
    "A" => { bg: "bg-emerald-100", text: "text-emerald-800", border: "border-emerald-200", dot: "bg-emerald-500" },
    "B" => { bg: "bg-green-100",   text: "text-green-800",   border: "border-green-200",   dot: "bg-green-500" },
    "C" => { bg: "bg-amber-100",   text: "text-amber-800",   border: "border-amber-200",   dot: "bg-amber-500" },
    "D" => { bg: "bg-orange-100",  text: "text-orange-800",  border: "border-orange-200",  dot: "bg-orange-500" },
    "E" => { bg: "bg-red-100",     text: "text-red-800",     border: "border-red-200",     dot: "bg-red-500" }
  }.freeze

  def niveau_badge(niveau, score: nil)
    return content_tag(:span, "—", class: "text-xs text-slate-300") if niveau.blank?
    s = NIVEAU_STYLES[niveau] || NIVEAU_STYLES["E"]
    info = ScoringService.niveau_info(niveau)
    label = score ? "#{niveau} · #{score}" : niveau
    content_tag(:span, label,
      class: "inline-flex items-center text-xs font-semibold px-2 py-0.5 rounded-full border #{s[:bg]} #{s[:text]} #{s[:border]}",
      title: info[:text]
    )
  end

  def niveau_bar(score)
    return "" if score.blank?
    pct = score.clamp(0, 100)
    color = case pct
      when 80..100 then "bg-emerald-500"
      when 60..79  then "bg-green-500"
      when 40..59  then "bg-amber-500"
      when 20..39  then "bg-orange-500"
      else              "bg-red-500"
    end
    content_tag(:div, class: "w-full bg-slate-100 rounded-full h-1.5 mt-1") do
      content_tag(:div, "", class: "#{color} h-1.5 rounded-full transition-all", style: "width: #{pct}%")
    end
  end
end
