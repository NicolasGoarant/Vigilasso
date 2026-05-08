#!/usr/bin/env ruby
# scripts/fetch_jo_phase4_v2.rb
#
# Pour chaque SIREN du fichier sirens_to_scrape_phase4_v2.csv (74 SIREN
# perdus entre phase 2-3 et phase 4), lance `rake scrape_jo:run Q=SIREN`
# et copie les nouveaux PDFs téléchargés vers data/pdfs_phase4_v2/.
#
# Resume logic     : data/fetch_jo_phase4_v2_done.csv enregistre chaque tentative.
# Hard cap         : 30 min wall-clock (cf. cap budget action 2 v2).
# Sleep entre SIREN: 2 s.

require 'csv'
require 'fileutils'
require 'set'
require 'shellwords'

PROJECT_ROOT  = File.expand_path('..', __dir__)
SAMPLE_CSV    = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data/sirens_to_scrape_phase4_v2.csv')
DONE_CSV      = File.join(PROJECT_ROOT, 'data/fetch_jo_phase4_v2_done.csv')
JO_DIR        = File.join(PROJECT_ROOT, 'tmp/jo_pdfs')
TARGET_DIR    = File.join(PROJECT_ROOT, 'data/pdfs_phase4_v2')
LOG_PATH      = '/tmp/fetch_jo_phase4_v2.log'

WALL_CLOCK_CAP = 30 * 60 # 30 min
SLEEP_BETWEEN  = 2.0

abort "#{SAMPLE_CSV} introuvable. Lance d'abord identify_lost_sirens.rb." unless File.exist?(SAMPLE_CSV)
FileUtils.mkdir_p(TARGET_DIR)
FileUtils.mkdir_p(JO_DIR)

LOG = File.open(LOG_PATH, 'a')
LOG.sync = true
def log(msg)
  line = "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
  puts line
  LOG.puts line
end

def jo_snapshot
  Dir.glob(File.join(JO_DIR, '*.pdf')).map { |p| File.basename(p) }.to_set
end

done = Set.new
if File.exist?(DONE_CSV)
  CSV.foreach(DONE_CSV, headers: true) { |r| done << r['siren'] if r['siren'] }
end

sample = CSV.read(SAMPLE_CSV, headers: true)
remaining = sample.reject { |r| done.include?(r['siren']) }

log "[Fetch JOAFE phase4 v2]"
log "  total sample        : #{sample.size}"
log "  déjà tentés         : #{done.size}"
log "  à traiter           : #{remaining.size}"
log "  cap wall-clock      : #{WALL_CLOCK_CAP / 60} min"
log "  sortie copie        : #{TARGET_DIR}"

if remaining.empty?
  log 'Rien à faire.'
  exit 0
end

mode = File.exist?(DONE_CSV) ? 'ab' : 'wb'
total_new_pdfs = 0
total_sirens_with_pdfs = 0
errors = 0
start = Time.now

CSV.open(DONE_CSV, mode) do |out|
  out << %w[siren expected_label status pdfs_found new_pdfs_copied error] if mode == 'wb'

  remaining.each_with_index do |row, idx|
    elapsed = Time.now - start
    if elapsed > WALL_CLOCK_CAP
      log "⏱  wall-clock cap atteint (#{elapsed.to_i}s > #{WALL_CLOCK_CAP}s) — arrêt propre"
      break
    end

    siren = row['siren']
    label = row['expected_label'].to_s.empty? ? '(non-binaire)' : row['expected_label']
    log "[#{idx + 1}/#{remaining.size}] SIREN=#{siren} (#{label}) — t=#{elapsed.to_i}s"

    snapshot_before = jo_snapshot
    cmd = "cd #{Shellwords.escape(PROJECT_ROOT)} && bundle exec rake scrape_jo:run Q=#{siren} 2>&1"
    rake_output = `#{cmd}`
    rake_exit = $?.exitstatus

    snapshot_after = jo_snapshot
    new_files = (snapshot_after - snapshot_before).select { |f| f.start_with?("#{siren}_") }

    if new_files.any?
      new_files.each do |f|
        src = File.join(JO_DIR, f)
        dst = File.join(TARGET_DIR, f)
        FileUtils.cp(src, dst) unless File.exist?(dst)
      end
      total_new_pdfs += new_files.size
      total_sirens_with_pdfs += 1
      log "    ⬇ #{new_files.size} PDF(s) → pdfs_phase4_v2/ : #{new_files.first(3).join(', ')}#{new_files.size > 3 ? '…' : ''}"
      out << [siren, row['expected_label'], 'ok', new_files.size, new_files.size, nil]
    elsif rake_exit != 0
      log "    ❌ rake exit=#{rake_exit} — extrait : #{rake_output.lines.last(3).map(&:strip).join(' | ').slice(0, 200)}"
      out << [siren, row['expected_label'], 'rake_error', 0, 0, "exit=#{rake_exit}"]
      errors += 1
    else
      out << [siren, row['expected_label'], 'no_pdf', 0, 0, nil]
    end
    out.flush
    sleep SLEEP_BETWEEN
  end
end

elapsed = Time.now - start
log ''
log "═══ Bilan fetch phase4 v2 ═══"
log "  durée               : #{(elapsed / 60).round(1)} min"
log "  SIREN avec ≥1 PDF   : #{total_sirens_with_pdfs}"
log "  total PDFs copiés   : #{total_new_pdfs}"
log "  rake erreurs        : #{errors}"
log "  → #{TARGET_DIR}"
log "  → log complet : #{LOG_PATH}"
