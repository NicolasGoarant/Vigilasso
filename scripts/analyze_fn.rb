#!/usr/bin/env ruby
# scripts/analyze_fn.rb
#
# Analyse des faux négatifs CRC : associations classées "fragile" par la
# Cour des comptes / une CRC mais notées A, B ou C par Vigil'Asso (= pas
# d'alerte au seuil C/D/E).
#
# Pour chaque FN, on demande à Haiku 4.5 de catégoriser la cause du raté :
#   (i)   fragilité non-comptable (gouvernance, dépendance subventions
#         pointée par la CRC mais pas encore dans les ratios)
#   (ii)  fonds dédiés / ressources affectées qui gonflent la solidité
#   (iii) défaut de calibration : les ratios sont mauvais, le scoring
#         aurait dû voir D ou E
#   (iv)  FN justifié : l'asso s'est redressée depuis le rapport CRC
#
# Lance via : ruby scripts/analyze_fn.rb
#
# Resume logic : skip les SIREN déjà dans fn_analysis.csv.
# Coût Haiku attendu : ~$0.05–0.10 sur ~16 cas.
#
# Note : on travaille avec ce qu'on a dans phase4_results.csv (résultat net,
# fonds propres, trésorerie + 5 sous-scores). Pas de re-extraction du PDF
# JOAFE — sinon le coût exploserait.

require 'csv'
require 'json'
require 'net/http'
require 'set'
require 'uri'

PROJECT_ROOT = File.expand_path('..', __dir__)
DATA_DIR     = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data')
INPUT_CSV    = File.join(DATA_DIR, 'phase4_results.csv')
OUTPUT_CSV   = File.join(DATA_DIR, 'fn_analysis.csv')

ANTHROPIC_API_URL = 'https://api.anthropic.com/v1/messages'
HAIKU_MODEL       = 'claude-haiku-4-5-20251001'

PRED_SAINS    = %w[A B C].freeze
SLEEP_BETWEEN = 1.5
RATE_LIMIT_SLEEP = 30

CATEGORIES = {
  'i'   => 'fragilité non-comptable',
  'ii'  => 'fonds dédiés / ressources affectées',
  'iii' => 'défaut de calibration',
  'iv'  => 'FN justifié (redressement)'
}.freeze

# Sous-scores Vigil'Asso et leur max (ScoringService::WEIGHTS)
SUBSCORE_MAX = {
  'rentabilite' => 30,
  'solidite'    => 25,
  'liquidite'   => 20,
  'autonomie'   => 15,
  'gouvernance' => 10
}.freeze

# ─── Formatage ───────────────────────────────────────────────────────

def fmt_eur(val)
  return '—' if val.to_s.empty?
  n = val.to_i
  abs_str = n.abs.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1 ').reverse
  sign = n.negative? ? '-' : ''
  "#{sign}#{abs_str} €"
end

def parse_detail(json_str)
  return {} if json_str.to_s.empty?
  JSON.parse(json_str)
rescue JSON::ParserError
  {}
end

def format_subscores(detail)
  SUBSCORE_MAX.map { |key, max|
    val = detail[key]
    val_str = val.nil? ? '?' : format('%.1f', val.to_f)
    "    #{key.ljust(12)}: #{val_str.rjust(5)} / #{max}"
  }.join("\n")
end

# ─── Prompt builder ──────────────────────────────────────────────────

def build_prompt(row, detail)
  <<~PROMPT
    Tu es analyste financier expert des associations loi 1901.

    Vigil'Asso est un système qui scote les associations sur 100 points et leur attribue une lettre A-E, à partir de cinq ratios calculés sur les comptes annuels :
      - rentabilité  (résultat exploitation / produits, max 30 pts)
      - solidité     (fonds propres / total bilan, max 25 pts)
      - liquidité    (trésorerie / produits, max 20 pts)
      - autonomie    (1 - subventions / produits, max 15 pts)
      - gouvernance  (CAC certifié, max 10 pts)
    Seuils : A ≥ 80, B ≥ 60, C ≥ 40, D ≥ 20, E < 20. Le seuil d'alerte produit est C/D/E.

    CAS À ANALYSER : une association que la Cour des comptes ou une chambre régionale a jugée financièrement fragile dans son rapport, mais que Vigil'Asso a noté A, B ou C (pas d'alerte). Ton travail : identifier pourquoi le scoring a raté ce cas.

    Choisis UNE des 4 catégories suivantes, celle qui colle le mieux :

    (i) fragilité non-comptable
        La CRC pointe des risques structurels — gouvernance défaillante, dépendance critique à un financeur, expansion mal maîtrisée, modèle économique fragile, déficit chronique mais lissé — qui ne sont pas encore visibles dans les ratios financiers à la date des comptes. Les chiffres sont OK ou mitigés mais pas alarmants.

    (ii) fonds dédiés / ressources affectées
        Les fonds propres affichés comprennent des subventions affectées, fonds dédiés, provisions réglementées ou apports avec droit de reprise qui gonflent artificiellement la solidité. Ratios trompeurs : le bilan paraît solide mais les ressources ne sont pas réellement disponibles pour absorber les pertes.

    (iii) défaut de calibration
        Les ratios SONT objectivement mauvais (rentabilité négative significative, fonds propres faibles, trésorerie tendue, autonomie basse) et auraient logiquement dû donner D ou E. Le scoring a un seuil mal calé, une pondération inadaptée, ou une formule qui rate cette configuration. Indice : plusieurs sous-scores en dessous de 50 % de leur max.

    (iv) FN justifié — redressement
        Le rapport CRC examine des exercices anciens où l'asso était fragile, mais les comptes récents (ceux scorés ici) montrent un retournement réel : redressement durable, plan de retour à l'équilibre exécuté, recapitalisation. Le score Vigil'Asso est juste, c'est le rapport qui est daté.

    ─── DONNÉES ───

    Titre rapport CRC :
    #{row['title']}

    Âge du rapport CRC : #{row['age_rapport_crc']} années

    Synthèse CRC :
    #{row['synthese_crc']}

    ─── COMPTES VIGIL'ASSO (exercice clos #{row['recent_date']}, exercice âgé de #{row['recent_age']} an) ───

    Score Vigil'Asso     : #{row['recent_score']} / 100  (niveau #{row['recent_niveau']})
    Statut comptable     : #{row['recent_statut']}
    Résultat net         : #{fmt_eur(row['recent_resultat_net'])}
    Fonds propres        : #{fmt_eur(row['recent_fonds_propres'])}
    Trésorerie           : #{fmt_eur(row['recent_tresorerie'])}

    Sous-scores Vigil'Asso (points obtenus / max) :
    #{format_subscores(detail)}

    ─── INSTRUCTION ───

    Réponds UNIQUEMENT par un objet JSON valide sur UNE seule ligne, sans texte ni markdown autour :
    {"category": "i" ou "ii" ou "iii" ou "iv", "reasoning": "<1 à 2 phrases en français qui justifient la catégorie en pointant le ou les éléments décisifs>", "confidence": "high" ou "medium" ou "low"}
  PROMPT
end

# ─── Appel Haiku ─────────────────────────────────────────────────────

def call_haiku(prompt)
  uri = URI(ANTHROPIC_API_URL)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 60

  req = Net::HTTP::Post.new(uri.request_uri)
  req['x-api-key']         = ENV.fetch('ANTHROPIC_API_KEY')
  req['anthropic-version'] = '2023-06-01'
  req['content-type']      = 'application/json'
  req.body = {
    model: HAIKU_MODEL,
    max_tokens: 400,
    messages: [{ role: 'user', content: prompt }]
  }.to_json

  resp = http.request(req)

  if resp.code == '429'
    warn "  ⏳ rate limit, sleep #{RATE_LIMIT_SLEEP}s"
    sleep RATE_LIMIT_SLEEP
    return call_haiku(prompt)
  end

  unless resp.code == '200'
    warn "  ⚠ HTTP #{resp.code} : #{resp.body.to_s[0, 200]}"
    return nil
  end

  data = JSON.parse(resp.body)
  text = data.dig('content', 0, 'text').to_s.strip
  if text =~ /(\{.*\})/m
    JSON.parse(Regexp.last_match(1))
  end
rescue StandardError => e
  warn "  ⚠ Erreur Haiku : #{e.message}"
  nil
end

# ─── Synthèse ────────────────────────────────────────────────────────

def show_summary
  unless File.exist?(OUTPUT_CSV)
    puts "Pas de #{OUTPUT_CSV}, rien à afficher."
    return
  end

  rows  = CSV.read(OUTPUT_CSV, headers: true)
  done  = rows.reject { |r| r['category'].to_s.empty? }
  total = done.size

  puts ''
  puts '═══ Synthèse des faux négatifs ═══'
  puts ''
  puts "Cas analysés avec succès : #{total}/#{rows.size}"
  return if total.zero?

  counts = Hash.new(0)
  done.each { |r| counts[r['category']] += 1 }

  puts ''
  puts 'Répartition des causes :'
  CATEGORIES.each do |key, label|
    n   = counts[key] || 0
    pct = (100.0 * n / total).round
    bar = '█' * (n.to_f / total * 24).round
    puts "  (#{key.ljust(3)}) #{label.ljust(42)} #{n.to_s.rjust(2)}/#{total}  #{pct.to_s.rjust(2)}%  #{bar}"
  end

  conf_counts = Hash.new(0)
  done.each { |r| conf_counts[r['confidence'].to_s] += 1 }
  puts ''
  puts "Confiance Haiku : high=#{conf_counts['high']}  medium=#{conf_counts['medium']}  low=#{conf_counts['low']}"
  puts ''
  puts "  → #{OUTPUT_CSV}"
end

# ─── Main ────────────────────────────────────────────────────────────

unless ENV['ANTHROPIC_API_KEY']
  abort "ANTHROPIC_API_KEY manquante.\n  export $(grep -v '^#' .env | xargs)"
end

abort "#{INPUT_CSV} introuvable. Lance d'abord scripts/phase4_run.rb." unless File.exist?(INPUT_CSV)

rows = CSV.read(INPUT_CSV, headers: true)

fn_rows = rows.select { |r|
  r['expected_label'] == 'fragile' &&
  PRED_SAINS.include?(r['recent_niveau']) &&
  !r['recent_score'].to_s.empty?
}

puts '[Analyse FN — faux négatifs CRC]'
puts "  total phase4    : #{rows.size}"
puts "  faux négatifs   : #{fn_rows.size}  (expected=fragile, predicted ∈ #{PRED_SAINS.join(', ')})"
puts "  modèle          : #{HAIKU_MODEL}"
puts ''

done_sirens = Set.new
if File.exist?(OUTPUT_CSV)
  CSV.foreach(OUTPUT_CSV, headers: true) { |r| done_sirens << r['siren'] if r['siren'] }
  puts "  (#{done_sirens.size} déjà analysés — reprise)"
end

remaining = fn_rows.reject { |r| done_sirens.include?(r['siren']) }
puts "  à faire         : #{remaining.size}"
puts ''

if remaining.empty?
  show_summary
  exit 0
end

mode = File.exist?(OUTPUT_CSV) ? 'ab' : 'wb'
CSV.open(OUTPUT_CSV, mode) do |out|
  if mode == 'wb'
    out << %w[siren title recent_niveau recent_score synthese_crc category category_label reasoning confidence]
  end

  remaining.each_with_index do |r, idx|
    detail = parse_detail(r['recent_detail'])
    title_short = r['title'].to_s.slice(0, 50)
    print "  [#{idx + 1}/#{remaining.size}] #{r['siren']} #{r['recent_niveau']}(#{r['recent_score']}) #{title_short}… "

    prompt = build_prompt(r, detail)
    result = call_haiku(prompt)

    if result.nil?
      out << [r['siren'], r['title'], r['recent_niveau'], r['recent_score'], r['synthese_crc'],
              nil, nil, 'erreur Haiku', nil]
      out.flush
      puts 'erreur'
      sleep SLEEP_BETWEEN
      next
    end

    cat        = result['category'].to_s.downcase
    label      = CATEGORIES[cat] || '?'
    reasoning  = result['reasoning'].to_s
    confidence = result['confidence'].to_s

    out << [r['siren'], r['title'], r['recent_niveau'], r['recent_score'], r['synthese_crc'],
            cat, label, reasoning, confidence]
    out.flush
    puts "(#{cat}) #{label} [#{confidence}]"
    sleep SLEEP_BETWEEN
  end
end

show_summary
