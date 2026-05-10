module AnalysesHelper
  NUTRI_COLORS = {
    "A" => "#1a7a4a",
    "B" => "#4caf7d",
    "C" => "#f5a623",
    "D" => "#e8622a",
    "E" => "#c0392b"
  }.freeze

  def nutriscore_gauge(niveau, score: nil)
    niveau ||= "E"
    levels = %w[A B C D E]
    seg_w = 70
    seg_h = 56
    gap   = 6
    total_w = (levels.size * seg_w) + ((levels.size - 1) * gap)
    height  = seg_h + 60

    svg = +%(<svg viewBox="0 0 #{total_w} #{height}" xmlns="http://www.w3.org/2000/svg" class="w-full h-auto">)

    levels.each_with_index do |lvl, i|
      x = i * (seg_w + gap)
      active = (lvl == niveau)
      fill = NUTRI_COLORS[lvl]
      opacity = active ? "1" : "0.35"
      scale_attr = active ? %( transform="translate(0,-6)") : ""

      svg << %(<g#{scale_attr}>)
      svg << %(<rect x="#{x}" y="0" width="#{seg_w}" height="#{seg_h}" rx="10" fill="#{fill}" fill-opacity="#{opacity}"/>)
      svg << %(<text x="#{x + seg_w / 2}" y="#{seg_h / 2 + 12}" text-anchor="middle" font-family="Fraunces, Georgia, serif" font-size="34" font-weight="700" fill="#ffffff" fill-opacity="#{active ? '1' : '0.85'}">#{lvl}</text>)
      svg << %(</g>)
    end

    active_index = levels.index(niveau) || 0
    pointer_x = active_index * (seg_w + gap) + seg_w / 2
    arrow_y = seg_h - 6

    svg << %(<polygon points="#{pointer_x - 10},#{arrow_y + 14} #{pointer_x + 10},#{arrow_y + 14} #{pointer_x},#{arrow_y + 30}" fill="#0f172a"/>)

    if score
      svg << %(<text x="#{pointer_x}" y="#{arrow_y + 56}" text-anchor="middle" font-family="Source Sans 3, sans-serif" font-size="13" font-weight="600" fill="#0f172a">#{score} / 100</text>)
    end

    svg << "</svg>"
    svg.html_safe
  end

  def sous_score_bar(value, max, niveau)
    pct = max.zero? ? 0 : (value.to_f / max * 100).clamp(0, 100)
    color = case (value.to_f / max)
    when 0.8..   then "bg-emerald-500"
    when 0.6...0.8 then "bg-green-500"
    when 0.4...0.6 then "bg-amber-500"
    when 0.2...0.4 then "bg-orange-500"
    else "bg-red-500"
    end
    content_tag(:div, class: "w-full bg-slate-100 rounded-full h-2") do
      content_tag(:div, "", class: "#{color} h-2 rounded-full transition-all", style: "width: #{pct}%")
    end
  end

  SOUS_SCORE_LABELS = {
    "rentabilite" => "Rentabilité",
    "solidite"    => "Solidité du bilan",
    "liquidite"   => "Liquidité",
    "autonomie"   => "Autonomie financière",
    "gouvernance" => "Gouvernance"
  }.freeze

  SOUS_SCORE_MAX = {
    "rentabilite" => 30, "solidite" => 25, "liquidite" => 20, "autonomie" => 15, "gouvernance" => 10
  }.freeze
end
