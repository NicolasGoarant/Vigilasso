#!/usr/bin/env ruby
# scripts/fetch_jo_for_bodacc_v11.rb
#
# Pour chaque SIREN du sample BODACC v11, lance `rake scrape_jo:run Q=SIREN`
# et copie les nouveaux PDFs téléchargés vers data/pdfs_positifs_v11/.
#
# La rake scrape_jo:run écrit dans tmp/jo_pdfs/ (chemin hardcodé). On la
# laisse intacte ; on identifie les nouveaux fichiers par diff de snapshot
# avant/après, filtrés sur le préfixe `{SIREN}_`.
#
# Resume logic     : data/fetch_jo_v11_done.csv enregistre chaque SIREN tenté.
# Hard cap wall-clock : 4 h (14 400 s). Au-delà, arrêt propre.
# Sleep entre SIREN  : 2 s.

require 'csv'
require 'fileutils'
require 'set'
require 'shellwords'

PROJECT_ROOT  = File.expand_path('..', __dir__)
SAMPLE_CSV    = File.join(PROJECT_ROOT, 'data/bodacc_sample_v11.csv')
DONE_CSV      = File.join(PROJECT_ROOT, 'data/fetch_jo_v11_done.csv')
JO_DIR        = File.join(PROJECT_ROOT, 'tmp/jo_pdfs')
TARGET_DIR    = File.join(PROJECT_ROOT, 'data/pdfs_positifs_v11')
LOG_PATH      = '/tmp/fetch_jo_v11.log'

WALL_CLOCK_CAP = 4 * 3600 # 4 heures
SLEEP_BETWEEN  = 2.0

abort "#{SAMPLE_CSV} introuvable. Lance d'abord select_bodacc_sample_v11.rb." unless File.exist?(SAMPLE_CSV)
FileUtils.mkdir_p(TARGET_DIR)
FileUtils.mkdir_p(JO_DIR)

LOG = File.open(LOG_PATH, 'a')
LOG.sync = true
def log(msg)
  line = "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
  puts line
  LOG.puts line
end

# ─── Snapshot helper ─────────────────────────────────────────────────

def jo_snapshot
  Dir.glob(File.join(JO_DIR, '*.pdf')).map { |p| File.basename(p) }.to_set
end

# ─── Resume ──────────────────────────────────────────────────────────

done = Set.new
if File.exist?(DONE_CSV)
  CSV.foreach(DONE_CSV, headers: true) { |r| done << r['siren'] if r['siren'] }
end

sample = CSV.read(SAMPLE_CSV, headers: true)
remaining = sample.reject { |r| done.include?(r['siren']) }

log "[Fetch JOAFE v11]"
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
  out << %w[siren status pdfs_found new_pdfs_copied error] if mode == 'wb'

  remaining.each_with_index do |row, idx|
    elapsed = Time.now - start
    if elapsed > WALL_CLOCK_CAP
      log "⏱  wall-clock cap atteint (#{elapsed.to_i}s > #{WALL_CLOCK_CAP}s) — arrêt propre"
      break
    end

    siren = row['siren']
    log "[#{idx + 1}/#{remaining.size}] SIREN=#{siren} (date_jugement=#{row['date_jugement']}) — t=#{elapsed.to_i}s"

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
      log "    ⬇ #{new_files.size} PDF(s) copiés vers pdfs_positifs_v11/ : #{new_files.first(3).join(', ')}#{new_files.size > 3 ? '…' : ''}"
      out << [siren, 'ok', new_files.size, new_files.size, nil]
    elsif rake_exit != 0
      log "    ❌ rake exit=#{rake_exit} — extrait : #{rake_output.lines.last(3).map(&:strip).join(' | ').slice(0, 200)}"
      out << [siren, 'rake_error', 0, 0, "exit=#{rake_exit}"]
      errors += 1
    else
      out << [siren, 'no_pdf', 0, 0, nil]
    end
    out.flush
    sleep SLEEP_BETWEEN
  end
end

elapsed = Time.now - start
log ''
log "═══ Bilan fetch v11 ═══"
log "  durée               : #{(elapsed / 60).round(1)} min"
log "  SIREN avec ≥1 PDF   : #{total_sirens_with_pdfs}"
log "  total PDFs copiés   : #{total_new_pdfs}"
log "  rake erreurs        : #{errors}"
log "  → #{TARGET_DIR}"
log "  → log complet : #{LOG_PATH}"
