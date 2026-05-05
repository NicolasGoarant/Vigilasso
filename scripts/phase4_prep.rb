#!/usr/bin/env ruby
# scripts/phase4_prep.rb — v2
#
# Prépare la phase 4 (extraction + scoring Vigil'Asso) avec DEUX PDFs par SIREN :
#   1. pdf_recent     : exercice le plus récent disponible (= score "actuel",
#                       ce que Vigil'Asso scorerait en production)
#   2. pdf_contemp    : exercice le plus récent ANTÉRIEUR à la pub_date du
#                       rapport CRC (= score "contemporain", ce que Vigil'Asso
#                       aurait dit au moment du contrôle de la chambre)
#
# Pour les rapports CRC très récents, les deux PDFs sont identiques
# (un seul score à calculer). Pour les rapports anciens, les PDFs diffèrent
# et tu auras deux scores : la divergence entre les deux mesure l'effet temporel.
#
# Génère phase4_inputs.csv (entrée pour ton ExtractionService + ScoringService).

require 'csv'
require 'date'

PROJECT_ROOT  = File.expand_path('..', __dir__)
DATA_DIR      = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data')
PHASE3_CSV    = File.join(DATA_DIR, 'sirens_for_phase3.csv')
PHASE4_CSV    = File.join(DATA_DIR, 'phase4_inputs.csv')
JOAFE_PDFS    = File.join(PROJECT_ROOT, 'tmp/jo_pdfs')

abort "#{PHASE3_CSV} introuvable." unless File.exist?(PHASE3_CSV)
abort "#{JOAFE_PDFS} introuvable." unless Dir.exist?(JOAFE_PDFS)

# ─── Parsing des PDFs ────────────────────────────────────────────────

def list_pdfs(siren)
  pattern = File.join(JOAFE_PDFS, "#{siren}_*.pdf")
  Dir.glob(pattern).map do |path|
    bn = File.basename(path)
    if bn =~ /\A\d+_(\d{2})(\d{2})(\d{4})(?:_rectif(\d+))?\.pdf\z/
      day, month, year = $1.to_i, $2.to_i, $3.to_i
      rectif = $4 ? $4.to_i : 0
      begin
        date = Date.new(year, month, day)
        { path: path, basename: bn, date: date, rectif: rectif }
      rescue StandardError
        nil
      end
    end
  end.compact
end

def latest_pdf(siren)
  pdfs = list_pdfs(siren)
  return nil if pdfs.empty?
  pdfs.sort_by { |p| [-p[:date].to_time.to_i, -p[:rectif]] }.first
end

def contemporary_pdf(siren, pub_date)
  return nil if pub_date.nil?
  pdfs = list_pdfs(siren)
  return nil if pdfs.empty?
  candidates = pdfs.select { |p| p[:date] < pub_date }
  return nil if candidates.empty?
  candidates.sort_by { |p| [-p[:date].to_time.to_i, -p[:rectif]] }.first
end

# ─── Préparation ─────────────────────────────────────────────────────

today = Date.today
rows = CSV.read(PHASE3_CSV, headers: true)

stats = {
  total:           0,
  no_pdf:          [],
  too_old_recent:  [], # exercice le plus récent > 8 ans
  ok:              0,
  no_contemp:      0,  # rapport CRC trop ancien, pas d'exercice antérieur dispo
  same_pdf:        0,  # cas où pdf_recent == pdf_contemp (rapport très récent)
  distinct_pdfs:   0
}

results = []

rows.each do |r|
  stats[:total] += 1
  siren = r['siren']
  pub_date_str = r['pub_date']
  pub_date = pub_date_str ? Date.parse(pub_date_str) : nil rescue nil

  pdf_recent = latest_pdf(siren)
  if pdf_recent.nil?
    stats[:no_pdf] << { siren: siren, label: r['expected_label'], title: r['title'] }
    next
  end

  age_recent = ((today - pdf_recent[:date]).to_f / 365.25).round(1)
  if age_recent > 8.0
    stats[:too_old_recent] << {
      siren: siren, label: r['expected_label'], title: r['title'],
      exercice: pdf_recent[:date].to_s, age: age_recent
    }
    next
  end

  pdf_contemp = contemporary_pdf(siren, pub_date)
  if pdf_contemp.nil?
    stats[:no_contemp] += 1
  elsif pdf_contemp[:path] == pdf_recent[:path]
    stats[:same_pdf] += 1
  else
    stats[:distinct_pdfs] += 1
  end

  contemp_lag = pdf_contemp && pub_date ?
    ((pub_date - pdf_contemp[:date]).to_f / 365.25).round(1) : nil

  stats[:ok] += 1
  results << {
    siren:           siren,
    expected_label:  r['expected_label'],
    title:           r['title'],
    pub_date_crc:    pub_date_str,
    age_rapport_crc: r['years_since_report'].to_f,
    synthese_crc:    r['synthese'],

    pdf_recent_path:     pdf_recent[:path],
    pdf_recent_basename: pdf_recent[:basename],
    pdf_recent_date:     pdf_recent[:date].to_s,
    pdf_recent_age:      age_recent,

    pdf_contemp_path:     pdf_contemp&.[](:path),
    pdf_contemp_basename: pdf_contemp&.[](:basename),
    pdf_contemp_date:     pdf_contemp&.[](:date)&.to_s,
    pdf_contemp_lag:      contemp_lag, # années entre pdf_contemp et pub_date

    same_pdf: pdf_contemp && pdf_contemp[:path] == pdf_recent[:path]
  }
end

results.sort_by! { |r| r[:age_rapport_crc] }

CSV.open(PHASE4_CSV, 'wb') do |out|
  out << %w[siren expected_label title
            pub_date_crc age_rapport_crc synthese_crc
            pdf_recent_path pdf_recent_basename pdf_recent_date pdf_recent_age
            pdf_contemp_path pdf_contemp_basename pdf_contemp_date pdf_contemp_lag
            same_pdf]
  results.each do |r|
    out << [
      r[:siren], r[:expected_label], r[:title],
      r[:pub_date_crc], r[:age_rapport_crc], r[:synthese_crc],
      r[:pdf_recent_path], r[:pdf_recent_basename], r[:pdf_recent_date], r[:pdf_recent_age],
      r[:pdf_contemp_path], r[:pdf_contemp_basename], r[:pdf_contemp_date], r[:pdf_contemp_lag],
      r[:same_pdf]
    ]
  end
end

# ─── Bilan ───────────────────────────────────────────────────────────

puts '═══ Bilan phase 3 → phase 4 ═══'
puts ''
puts "SIREN dans sirens_for_phase3.csv             : #{stats[:total]}"
puts "  sans PDF JOAFE (perdus)                    : #{stats[:no_pdf].size}"
puts "  exercice le plus récent > 8 ans (exclus)   : #{stats[:too_old_recent].size}"
puts "  EXPLOITABLES                                : #{stats[:ok]}"
puts ''
puts "Sur les #{stats[:ok]} exploitables :"
puts "  pdf_recent et pdf_contemp identiques       : #{stats[:same_pdf]}  (rapport très récent)"
puts "  PDFs distincts (deux scores à calculer)    : #{stats[:distinct_pdfs]}"
puts "  pas de pdf_contemp trouvé                  : #{stats[:no_contemp]}  (rapport antérieur à tous les exercices)"
puts ''

unless stats[:no_pdf].empty?
  puts "SIREN sans PDF JOAFE :"
  stats[:no_pdf].each { |x| puts "  #{x[:siren]} #{x[:label].ljust(7)} #{x[:title].slice(0, 50)}" }
  puts ''
end

unless stats[:too_old_recent].empty?
  puts "SIREN exclus (dernier exercice > 8 ans) :"
  stats[:too_old_recent].each { |x|
    puts "  #{x[:siren]} #{x[:label].ljust(7)} dernier exercice #{x[:exercice]} (#{x[:age]} ans)  #{x[:title].slice(0, 40)}"
  }
  puts ''
end

# Sous-échantillons
if stats[:ok].positive?
  puts 'Sous-échantillons selon récence du rapport CRC :'
  [3.0, 5.0, 8.0].each do |th|
    sub = results.select { |r| r[:age_rapport_crc] <= th }
    pos = sub.count { |r| r[:expected_label] == 'fragile' }
    neg = sub.count { |r| r[:expected_label] == 'sain' }
    distinct = sub.count { |r| !r[:same_pdf] && r[:pdf_contemp_path] }
    puts "  ≤ #{th} ans : #{sub.size} cas (#{pos} fragile + #{neg} sain), #{distinct} avec pdf_contemp distinct"
  end
  puts ''
end

puts "  → #{PHASE4_CSV}"
puts ''
puts 'Pour la phase 4, deux runs à faire dans Rails :'
puts ''
puts "  rails runner '"
puts "    require \"csv\""
puts "    CSV.foreach(\"#{PHASE4_CSV}\", headers: true) do |r|"
puts "      pdf_recent  = r[\"pdf_recent_path\"]"
puts "      pdf_contemp = r[\"pdf_contemp_path\"]"
puts "      score_recent  = ScoringService.call(ExtractionService.call(pdf_recent))"
puts "      score_contemp = pdf_contemp ? ScoringService.call(ExtractionService.call(pdf_contemp)) : nil"
puts "      # persiste : siren, expected_label, score_recent, score_contemp, ..."
puts "    end"
puts "  '"
