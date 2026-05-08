#!/usr/bin/env ruby
# scripts/phase4_prep_v2.rb
#
# Adaptation de scripts/phase4_prep.rb pour la vague v2 (74 SIREN scrapés
# dans data/pdfs_phase4_v2/).
#
# Diffère de la version v1 sur trois points :
#   1. Source SIREN : sirens_to_scrape_phase4_v2.csv (et non sirens_for_phase3.csv).
#   2. Source PDFs  : data/pdfs_phase4_v2/ (et non tmp/jo_pdfs/).
#   3. Pas de filtre « exercice > 8 ans » : on garde tout — l'IC se resserre
#      mieux avec un peu de bruit temporel qu'avec un sample exclu.
#
# Pour la pub_date du rapport CRC, on n'a pas le champ dans
# sirens_to_scrape_phase4_v2.csv ; on l'extrait à la volée depuis
# audit_pdfs.csv (jointure via siren). Pas de pub_date → pdf_contemp = nil
# (on scorera uniquement le PDF recent dans phase4_run_v2.rb).
#
# Output : app/assets/fichiers_internes/data/phase4_inputs_v2.csv
#          schéma identique à phase4_inputs.csv.

require 'csv'
require 'date'

PROJECT_ROOT = File.expand_path('..', __dir__)
DATA_DIR     = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data')
SAMPLE_CSV   = File.join(DATA_DIR, 'sirens_to_scrape_phase4_v2.csv')
AUDIT_CSV    = File.join(DATA_DIR, 'audit_pdfs.csv')
REPORTS_CSV  = File.join(DATA_DIR, 'reports.csv')
OUT_CSV      = File.join(DATA_DIR, 'phase4_inputs_v2.csv')
PDFS_DIR     = File.join(PROJECT_ROOT, 'data/pdfs_phase4_v2')

abort "#{SAMPLE_CSV} introuvable." unless File.exist?(SAMPLE_CSV)
abort "#{PDFS_DIR} introuvable. Lance d'abord fetch_jo_phase4_v2.rb."   unless Dir.exist?(PDFS_DIR)

# ─── Index reports.csv (url → pub_date) ──────────────────────────────

reports = {}
if File.exist?(REPORTS_CSV)
  CSV.foreach(REPORTS_CSV, headers: true) do |r|
    u = r['url'].to_s.strip
    next if u.empty?
    reports[u] ||= r['pub_date']
  end
end

# ─── Index audit_pdfs.csv (siren → url) pour fallback ────────────────

audit_url_for_siren = {}
if File.exist?(AUDIT_CSV)
  CSV.foreach(AUDIT_CSV, headers: true) do |r|
    s = r['siren'].to_s.strip
    next if s.empty?
    audit_url_for_siren[s] ||= r['url']
  end
end

# ─── Helpers PDF ─────────────────────────────────────────────────────

def list_pdfs(dir, siren)
  Dir.glob(File.join(dir, "#{siren}_*.pdf")).map do |path|
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

def latest_pdf(pdfs)
  return nil if pdfs.empty?
  pdfs.sort_by { |p| [-p[:date].to_time.to_i, -p[:rectif]] }.first
end

def contemp_pdf(pdfs, pub_date)
  return nil if pub_date.nil? || pdfs.empty?
  candidates = pdfs.select { |p| p[:date] < pub_date }
  return nil if candidates.empty?
  candidates.sort_by { |p| [-p[:date].to_time.to_i, -p[:rectif]] }.first
end

# ─── Run ─────────────────────────────────────────────────────────────

today = Date.today
sample = CSV.read(SAMPLE_CSV, headers: true)

stats = { total: 0, no_pdf: 0, ok: 0, same_pdf: 0, distinct: 0, no_contemp: 0 }
results = []

sample.each do |r|
  stats[:total] += 1
  siren = r['siren']
  pdfs  = list_pdfs(PDFS_DIR, siren)

  if pdfs.empty?
    stats[:no_pdf] += 1
    next
  end

  pdf_recent = latest_pdf(pdfs)
  age_recent = ((today - pdf_recent[:date]).to_f / 365.25).round(1)

  url = r['url'].to_s.strip
  url = audit_url_for_siren[siren].to_s if url.empty?
  pub_date_str = reports[url]
  pub_date = nil
  begin
    pub_date = pub_date_str ? Date.parse(pub_date_str) : nil
  rescue StandardError
    pub_date = nil
  end

  contemp = contemp_pdf(pdfs, pub_date)
  age_rapport_crc = pub_date ? ((today - pub_date).to_f / 365.25).round(1) : nil

  if contemp.nil?
    stats[:no_contemp] += 1
  elsif contemp[:path] == pdf_recent[:path]
    stats[:same_pdf] += 1
  else
    stats[:distinct] += 1
  end

  contemp_lag = contemp && pub_date ? ((pub_date - contemp[:date]).to_f / 365.25).round(1) : nil

  stats[:ok] += 1
  results << {
    siren:           siren,
    expected_label:  r['expected_label'],
    title:           r['title'],
    pub_date_crc:    pub_date_str,
    age_rapport_crc: age_rapport_crc,
    synthese_crc:    r['synthese_crc'],

    pdf_recent_path:     pdf_recent[:path],
    pdf_recent_basename: pdf_recent[:basename],
    pdf_recent_date:     pdf_recent[:date].to_s,
    pdf_recent_age:      age_recent,

    pdf_contemp_path:     contemp&.[](:path),
    pdf_contemp_basename: contemp&.[](:basename),
    pdf_contemp_date:     contemp&.[](:date)&.to_s,
    pdf_contemp_lag:      contemp_lag,

    same_pdf: contemp && contemp[:path] == pdf_recent[:path]
  }
end

# Tri stable : binaires en tête (utiles pour matrice)
results.sort_by! do |r|
  bucket = case r[:expected_label]
           when 'fragile' then 0
           when 'sain'    then 1
           else                2
           end
  [bucket, r[:siren]]
end

CSV.open(OUT_CSV, 'wb') do |out|
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

puts '═══ Bilan phase4_prep_v2 ═══'
puts ''
puts "  SIREN sample (sirens_to_scrape_phase4_v2)  : #{stats[:total]}"
puts "  Sans aucun PDF dans pdfs_phase4_v2/        : #{stats[:no_pdf]}"
puts "  EXPLOITABLES                                : #{stats[:ok]}"
binary  = results.count { |r| %w[fragile sain].include?(r[:expected_label]) }
non_bin = results.size - binary
puts "    dont label binaire (matrice CRC)         : #{binary}"
puts "    dont label non-binaire (exploratoire)    : #{non_bin}"
puts ''
puts "  same_pdf (recent == contemp)               : #{stats[:same_pdf]}"
puts "  PDFs distincts (recent + contemp)          : #{stats[:distinct]}"
puts "  pas de pdf_contemp (rapport antérieur)     : #{stats[:no_contemp]}"
puts ''
puts "  → #{OUT_CSV}"
