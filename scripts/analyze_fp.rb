#!/usr/bin/env ruby
# scripts/analyze_fp.rb
#
# Analyse les faux positifs Vigil'Asso vs CRC sur le sample phase 4 (n=38).
# Pour chaque FP (Vigi classe en C/D/E alors que la CRC conclut "sain"),
# appelle Haiku 4.5 pour catégoriser la cause de la divergence.
#
# Source  : app/assets/fichiers_internes/data/phase4_results.csv
# Output  : app/assets/fichiers_internes/data/fp_analysis.csv
# Log     : /tmp/analyze_fp.log
#
# Lance via : ruby scripts/analyze_fp.rb

require 'csv'
require 'json'
require 'set'
require 'net/http'
require 'uri'

# dotenv pour ANTHROPIC_API_KEY
begin
  require 'dotenv'
  Dotenv.load(File.expand_path('../.env', __dir__))
rescue LoadError
end

PROJECT_ROOT = File.expand_path('..', __dir__)
INPUT_CSV    = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data/phase4_results.csv')
OUTPUT_CSV   = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data/fp_analysis.csv')
LOG_PATH     = '/tmp/analyze_fp.log'

MODEL        = 'claude-haiku-4-5-20251001'
MAX_TOKENS   = 800
SLEEP_BETWEEN = 1.5

INPUT_PRICE  = 1.0  / 1_000_000  # Haiku 4.5 : input $1/MTok
OUTPUT_PRICE = 5.0  / 1_000_000  # output $5/MTok

abort "ANTHROPIC_API_KEY manquante." unless ENV['ANTHROPIC_API_KEY']
abort "#{INPUT_CSV} introuvable." unless File.exist?(INPUT_CSV)

LOG = File.open(LOG_PATH, 'a')
LOG.sync = true
def log(msg)
  line = "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
  puts line
  LOG.puts line
end

# ─── Sélection FP ────────────────────────────────────────────────────

def fragile_label?(niveau)
  %w[C D E].include?(niveau.to_s.upcase)
end

def sain_crc?(label)
  label.to_s.downcase =~ /sain|non.?fragile|^ok$/
end

fps = []
CSV.foreach(INPUT_CSV, headers: true) do |r|
  next unless fragile_label?(r['recent_niveau']) && sain_crc?(r['expected_label'])
  fps << r.to_h
end

log "[Analyze FP — Haiku 4.5]"
log "  FP identifiés : #{fps.size}"

# ─── Resume ──────────────────────────────────────────────────────────

done_sirens = Set.new
if File.exist?(OUTPUT_CSV)
  CSV.foreach(OUTPUT_CSV, headers: true) { |r| done_sirens << r['siren'] if r['siren'] }
end
remaining = fps.reject { |fp| done_sirens.include?(fp['siren']) }
log "  Déjà traités : #{done_sirens.size}, à traiter : #{remaining.size}"

if remaining.empty?
  log 'Rien à faire.'
  exit 0
end

# ─── Prompt Haiku ────────────────────────────────────────────────────

SYSTEM_PROMPT = <<~TXT.strip
  Tu es un expert-comptable spécialisé dans les associations loi 1901
  françaises. Tu analyses pourquoi un scoring automatique de fragilité
  financière diverge d'une analyse qualitative menée par une Chambre
  régionale des comptes (CRC).
TXT

USER_PROMPT_TEMPLATE = <<~TXT
  Cas analysé :
  - Nom : %{nom}
  - SIREN : %{siren}
  - Conclusion CRC (synthèse) : %{synthese_crc}
  - Niveau Vigil'Asso : %{niveau} (score %{score}/100)
  - Sous-scores Vigil'Asso (sur leur poids max) :
      rentabilité  : %{pts_rent} / 30
      solidité     : %{pts_soli} / 25
      liquidité    : %{pts_liqu} / 20
      autonomie    : %{pts_auto} / 15
      gouvernance  : %{pts_gouv} / 10
  - Données comptables récentes (JOAFE) :
      résultat net          : %{resultat_net} €
      fonds propres         : %{fonds_propres} €
      trésorerie            : %{tresorerie} €
      statut comptable      : %{statut}

  La CRC conclut que cette association est **saine / non-fragile**, mais
  Vigil'Asso la classe en zone d'alerte (C, D ou E). Pourquoi cette divergence ?

  Catégorise la cause parmi :
    (i)   Fonds dédiés/affectés : la trésorerie ou les fonds propres
          paraissent fragiles mais sont en réalité des subventions
          affectées, non disponibles librement.
    (ii)  Profil sectoriel atypique : modèle économique normal pour le
          secteur (fondation très liquide, asso quasi-lucrative,
          office de tourisme adossé à des EPCI…) que le scoring
          pénalise injustement.
    (iii) Volatilité conjoncturelle : un exercice exceptionnel (Covid,
          sinistre, restructuration) tire le score vers le bas mais
          la trajectoire pluriannuelle reste saine.
    (iv)  CRC indulgente : Vigil'Asso a raison sur la fragilité
          comptable mais le rapport CRC tempère ou minimise.
    (v)   Autre : à préciser.

  Réponds STRICTEMENT en JSON, sans markdown, avec les clés :
    "category"   : "i" | "ii" | "iii" | "iv" | "v"
    "reasoning"  : 1-2 phrases concises
    "confidence" : "high" | "medium" | "low"
TXT

def call_haiku(payload)
  uri = URI('https://api.anthropic.com/v1/messages')
  req = Net::HTTP::Post.new(uri)
  req['x-api-key']         = ENV['ANTHROPIC_API_KEY']
  req['anthropic-version'] = '2023-06-01'
  req['content-type']      = 'application/json'
  req.body = JSON.generate(
    model:      MODEL,
    max_tokens: MAX_TOKENS,
    system:     SYSTEM_PROMPT,
    messages:   [{ role: 'user', content: payload }]
  )
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |h| h.request(req) }
  raise "HTTP #{res.code}: #{res.body[0..300]}" unless res.code.to_i == 200
  body = JSON.parse(res.body)
  text = body['content'][0]['text'].to_s
  text = text.gsub(/\A```(?:json)?\n?/, '').gsub(/\n?```\z/, '').strip
  usage = body['usage'] || {}
  [JSON.parse(text), usage]
end

# ─── Run ─────────────────────────────────────────────────────────────

CSV_HEADERS = %w[
  siren nom expected_label recent_niveau recent_score
  pts_rent pts_soli pts_liqu pts_auto pts_gouv
  recent_resultat_net recent_fonds_propres recent_tresorerie recent_statut
  synthese_crc category reasoning confidence
].freeze

mode = File.exist?(OUTPUT_CSV) ? 'ab' : 'wb'
total_cost = 0.0
ok = 0; errs = 0

CSV.open(OUTPUT_CSV, mode) do |out|
  out << CSV_HEADERS if mode == 'wb'

  remaining.each_with_index do |fp, idx|
    detail = JSON.parse(fp['recent_detail'].to_s) rescue {}
    nom = fp['title'].to_s.gsub(/^Association\s+/, '').gsub(/[«»"]/, '').strip
    payload = USER_PROMPT_TEMPLATE % {
      nom:           nom,
      siren:         fp['siren'],
      synthese_crc:  fp['synthese_crc'],
      niveau:        fp['recent_niveau'],
      score:         fp['recent_score'],
      pts_rent:      detail['rentabilite'],
      pts_soli:      detail['solidite'],
      pts_liqu:      detail['liquidite'],
      pts_auto:      detail['autonomie'],
      pts_gouv:      detail['gouvernance'],
      resultat_net:  fp['recent_resultat_net'],
      fonds_propres: fp['recent_fonds_propres'],
      tresorerie:    fp['recent_tresorerie'],
      statut:        fp['recent_statut']
    }

    log "[#{idx + 1}/#{remaining.size}] #{fp['siren']} #{fp['recent_niveau']}/#{fp['recent_score']} — #{nom[0..60]}"
    begin
      parsed, usage = call_haiku(payload)
      cost = usage['input_tokens'].to_i * INPUT_PRICE + usage['output_tokens'].to_i * OUTPUT_PRICE
      total_cost += cost
      out << [
        fp['siren'], nom, fp['expected_label'], fp['recent_niveau'], fp['recent_score'],
        detail['rentabilite'], detail['solidite'], detail['liquidite'], detail['autonomie'], detail['gouvernance'],
        fp['recent_resultat_net'], fp['recent_fonds_propres'], fp['recent_tresorerie'], fp['recent_statut'],
        fp['synthese_crc'], parsed['category'], parsed['reasoning'], parsed['confidence']
      ]
      out.flush
      ok += 1
      log "    → cat=#{parsed['category']} conf=#{parsed['confidence']} (+$#{format('%.4f', cost)}, cumul $#{format('%.4f', total_cost)})"
    rescue StandardError => e
      errs += 1
      out << [
        fp['siren'], nom, fp['expected_label'], fp['recent_niveau'], fp['recent_score'],
        detail['rentabilite'], detail['solidite'], detail['liquidite'], detail['autonomie'], detail['gouvernance'],
        fp['recent_resultat_net'], fp['recent_fonds_propres'], fp['recent_tresorerie'], fp['recent_statut'],
        fp['synthese_crc'], nil, "error: #{e.class}: #{e.message[0..150]}", nil
      ]
      out.flush
      log "    ❌ #{e.message[0..150]}"
    end

    sleep SLEEP_BETWEEN
  end
end

log ''
log '═══ Bilan analyze_fp ═══'
log "  ok     : #{ok}"
log "  errs   : #{errs}"
log "  coût   : $#{format('%.4f', total_cost)} (Haiku 4.5)"
log "  → #{OUTPUT_CSV}"
