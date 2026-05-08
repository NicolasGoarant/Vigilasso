#!/usr/bin/env ruby
# scripts/extract_alpha.rb
#
# Extraction enrichie ExtractionServiceAlpha pour les 38 PDFs CRC
# (compte le plus récent par SIREN, depuis phase4_results.csv → recent_pdf).
#
# Lance via : bundle exec rails runner scripts/extract_alpha.rb
#
# Source PDFs : tmp/jo_pdfs/{recent_pdf}
# Output CSV  : app/assets/fichiers_internes/data/scores_alpha.csv
# Resume      : skip les fichiers déjà présents dans le CSV
# Plafond     : $10 strict (Sonnet 4.5)
# Rate limit  : sleep 3 s, retry expo (30/60/120 s) sur 429.

require 'csv'
require 'set'
require 'base64'

PROJECT_ROOT  = File.expand_path('..', __dir__)
INPUT_CSV     = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data/phase4_results.csv')
PDFS_DIR      = File.join(PROJECT_ROOT, 'tmp/jo_pdfs')
OUTPUT_CSV    = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data/scores_alpha.csv')
LOG_PATH      = '/tmp/extract_alpha.log'

SLEEP_BETWEEN = 3.0
MAX_RETRIES   = 3
COST_CAP_USD  = 10.0
INPUT_PRICE   = 3.0  / 1_000_000
OUTPUT_PRICE  = 15.0 / 1_000_000

CSV_HEADERS = %w[
  siren fichier cloture nom ville
  total_produits resultat_exploitation resultat_net
  fonds_propres tresorerie emprunts total_bilan
  subv_sur_produits_pct masse_sal_pct fp_bilan_pct etp
  cac_certifie statut notes
  fonds_dedies_pct secteur_atypique secteur_atypique_justification
  error
].freeze

abort 'ANTHROPIC_API_KEY manquante.' unless ENV['ANTHROPIC_API_KEY']
abort "#{INPUT_CSV} introuvable." unless File.exist?(INPUT_CSV)

LOG = File.open(LOG_PATH, 'a')
LOG.sync = true
def log(msg)
  line = "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
  puts line
  LOG.puts line
end

# ─── Cibles ──────────────────────────────────────────────────────────

targets = []
CSV.foreach(INPUT_CSV, headers: true) do |r|
  next unless r['recent_pdf']
  pdf_path = File.join(PDFS_DIR, r['recent_pdf'])
  unless File.exist?(pdf_path)
    log "  PDF manquant : #{r['recent_pdf']}"
    next
  end
  targets << { siren: r['siren'], fichier: r['recent_pdf'], path: pdf_path }
end

done_files = Set.new
if File.exist?(OUTPUT_CSV)
  CSV.foreach(OUTPUT_CSV, headers: true) { |r| done_files << r['fichier'] if r['fichier'] }
end
remaining = targets.reject { |t| done_files.include?(t[:fichier]) }

log '[Extract α — Sonnet 4.5 enrichi (fonds_dedies + secteur)]'
log "  PDFs cibles  : #{targets.size}"
log "  Déjà extraits : #{done_files.size}"
log "  À extraire   : #{remaining.size}"
log "  Plafond      : $#{COST_CAP_USD}"

if remaining.empty?
  log 'Rien à faire.'
  exit 0
end

require 'anthropic'

# ─── Wrapper avec retry sur 429 ──────────────────────────────────────

def call_alpha_with_retry(pdf_path)
  retries = 0
  loop do
    parsed, usage, err = ExtractionServiceAlpha.new(pdf_path).call
    if err && err =~ /429|rate.?limit|overloaded/i && retries < MAX_RETRIES
      retries += 1
      wait = 30 * (2**(retries - 1))
      log "    ⏳ rate limit, sleep #{wait}s (retry #{retries}/#{MAX_RETRIES})"
      sleep wait
      next
    end
    return [parsed, usage, err]
  end
end

# ─── Run ─────────────────────────────────────────────────────────────

mode = File.exist?(OUTPUT_CSV) ? 'ab' : 'wb'
total_cost = 0.0
ok = 0; errors = 0
stopped_reason = nil
start = Time.now

CSV.open(OUTPUT_CSV, mode) do |out|
  out << CSV_HEADERS if mode == 'wb'

  remaining.each_with_index do |t, idx|
    log "[#{idx + 1}/#{remaining.size}] #{t[:fichier]} — coût cumulé $#{format('%.2f', total_cost)}"

    parsed, usage, err = call_alpha_with_retry(t[:path])
    if usage
      cost = usage.input_tokens.to_i * INPUT_PRICE + usage.output_tokens.to_i * OUTPUT_PRICE
      total_cost += cost
    end

    if parsed.nil?
      out << [t[:siren], t[:fichier], nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, err]
      out.flush
      errors += 1
      log "    ❌ #{err}"
    else
      out << [
        t[:siren], t[:fichier],
        parsed['cloture'], parsed['nom'], parsed['ville'],
        parsed['total_produits'], parsed['resultat_exploitation'], parsed['resultat_net'],
        parsed['fonds_propres'], parsed['tresorerie'], parsed['emprunts'], parsed['total_bilan'],
        parsed['subv_sur_produits_pct'], parsed['masse_sal_pct'], parsed['fp_bilan_pct'], parsed['etp'],
        parsed['cac_certifie'], parsed['statut'], parsed['notes'],
        parsed['fonds_dedies_pct'], parsed['secteur_atypique'], parsed['secteur_atypique_justification'],
        nil
      ]
      out.flush
      ok += 1
      log "    ✓ fonds_dedies=#{parsed['fonds_dedies_pct']} secteur=#{parsed['secteur_atypique']} (+$#{format('%.4f', usage ? usage.input_tokens * INPUT_PRICE + usage.output_tokens * OUTPUT_PRICE : 0)})"
    end

    if total_cost > COST_CAP_USD
      stopped_reason = "plafond $#{COST_CAP_USD} atteint (cumul $#{format('%.2f', total_cost)})"
      log "🛑 #{stopped_reason}"
      break
    end

    sleep SLEEP_BETWEEN
  end
end

elapsed = Time.now - start
log ''
log '═══ Bilan extract α ═══'
log "  durée         : #{(elapsed / 60).round(1)} min"
log "  PDFs traités  : #{ok + errors}"
log "  ok            : #{ok}"
log "  erreurs       : #{errors}"
log "  coût total    : $#{format('%.2f', total_cost)} (plafond $#{COST_CAP_USD})"
log "  arrêt         : #{stopped_reason || 'non'}"
log "  → #{OUTPUT_CSV}"
