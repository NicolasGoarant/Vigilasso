#!/usr/bin/env ruby
# scripts/audit_pdfs.rb
#
# Audit des conclusions des rapports CRC par Haiku 4.5 pour catégoriser
# le sujet principal (fragilité financière, gouvernance, conformité, etc.).
#
# Deux modes :
#   ruby scripts/audit_pdfs.rb         → sample 20 rapports random (seed=42, repro)
#   ruby scripts/audit_pdfs.rb all     → tous les SIREN high+medium de sirens_verified.csv
#
# Resume logic : si audit_pdfs.csv existe déjà, les rapports déjà traités
# (URL présente) sont skipés. Tu peux donc enchaîner sample puis all sans
# perdre le travail.
#
# En mode 'all', un fichier sirens_for_phase3.csv est aussi généré : la
# liste des SIREN avec leur label attendu (fragile / sain) prête à être
# passée à la phase 3 (récupération JOAFE + scoring Vigil'Asso).
#
# Pré-requis : pdftotext (paquet poppler-utils sur Ubuntu)
# Coût : ~$0.15 mode sample, ~$0.80 mode all (incrémental après sample)
# Durée : ~2 min sample, ~9 min all (incrémental)

require 'csv'
require 'json'
require 'net/http'
require 'set'
require 'uri'
require 'fileutils'

PROJECT_ROOT = File.expand_path('..', __dir__)
DATA_DIR     = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data')
REPORTS_CSV  = File.join(DATA_DIR, 'reports.csv')
VERIFIED_CSV = File.join(DATA_DIR, 'sirens_verified.csv')
PDFS_DIR     = File.join(DATA_DIR, 'crc_pdfs')
AUDIT_CSV    = File.join(DATA_DIR, 'audit_pdfs.csv')
PHASE3_CSV   = File.join(DATA_DIR, 'sirens_for_phase3.csv')

ANTHROPIC_API_URL = 'https://api.anthropic.com/v1/messages'
HAIKU_MODEL       = 'claude-haiku-4-5-20251001'

SAMPLE_SIZE = 20
MAX_CHARS   = 25_000
RANDOM_SEED = 42

CATEGORIES = {
  'fragilite_financiere'      => 'déficit, fonds propres dégradés, trésorerie, dépendance subventions',
  'gouvernance'               => 'CA défaillant, conflits intérêts, dirigeants en cause, statuts',
  'conformite'                => 'marchés publics, RH, fiscalité, subventions sans justification',
  'performance_operationnelle' => 'missions mal remplies, indicateurs en baisse',
  'strategie'                 => 'pivot, fusion, dissolution, positionnement',
  'rien_critique'             => 'rapport globalement positif'
}

# ─── Extraction PDF ──────────────────────────────────────────────────

def extract_text(pdf_path)
  full = `pdftotext -layout "#{pdf_path}" - 2>/dev/null`
  return nil if full.nil? || full.strip.empty?

  if full.length <= MAX_CHARS
    full
  else
    full[0, 8_000] + "\n\n[…milieu du rapport coupé…]\n\n" + full[-17_000..-1]
  end
end

# ─── Classification Claude ───────────────────────────────────────────

def classify_report(title, text)
  cats_listing = CATEGORIES.map { |k, v| "    - \"#{k}\" : #{v}" }.join("\n")

  prompt = <<~PROMPT
    Tu es analyste des rapports de la Cour des comptes et des chambres régionales (CRC). Tu reçois des extraits d'un rapport (synthèse + conclusions/recommandations) portant sur UNE association ou fondation.

    Identifie les SUJETS PRINCIPAUX des conclusions et recommandations. Catégories possibles :
    #{cats_listing}

    Une catégorie "primary" + une liste "categories" qui inclut tout ce qui est traité significativement (pas juste mentionné en passant).

    Indique aussi explicitement si le rapport mentionne : déficit comptable, fonds propres négatifs ou très dégradés, trésorerie tendue, dépendance critique aux subventions publiques. Ces indicateurs servent à savoir si le cas peut servir à valider un modèle de détection de fragilité.

    TITRE DU RAPPORT : #{title}

    EXTRAITS DU RAPPORT :
    #{text}

    Réponds UNIQUEMENT par un objet JSON valide sur UNE seule ligne, sans aucun autre texte :
    {"primary": "<une catégorie>", "categories": ["<cat1>", "<cat2>"], "mentions_deficit": <bool>, "mentions_fonds_propres_negatifs": <bool>, "mentions_tresorerie_tendue": <bool>, "mentions_dependance_subventions": <bool>, "synthese": "<15-25 mots qui résument la critique principale>"}
  PROMPT

  uri = URI(ANTHROPIC_API_URL)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 60

  req = Net::HTTP::Post.new(uri.request_uri)
  req['x-api-key'] = ENV.fetch('ANTHROPIC_API_KEY')
  req['anthropic-version'] = '2023-06-01'
  req['content-type'] = 'application/json'
  req.body = {
    model: HAIKU_MODEL,
    max_tokens: 500,
    messages: [{ role: 'user', content: prompt }]
  }.to_json

  resp = http.request(req)

  if resp.code == '429'
    warn "  ⏳ rate limit, sleep 30s"
    sleep 30
    return classify_report(title, text)
  end

  unless resp.code == '200'
    warn "  ⚠ HTTP #{resp.code} : #{resp.body.to_s[0, 200]}"
    return nil
  end

  data = JSON.parse(resp.body)
  text_response = data.dig('content', 0, 'text').to_s.strip
  if text_response =~ /(\{.*\})/m
    JSON.parse(Regexp.last_match(1))
  end
rescue StandardError => e
  warn "  ⚠ Erreur Claude : #{e.message}"
  nil
end

# ─── Construction de la liste de cibles selon le mode ────────────────

def targets_sample(siren_by_url)
  reports = CSV.read(REPORTS_CSV, headers: true)
    .select { |r| r['is_loi_1901'] == 'true' }
    .map { |r|
      slug = r['url'].split('/').last
      { url: r['url'], title: r['title'], slug: slug, siren: siren_by_url[r['url']] }
    }
    .reject { |r| r[:slug].empty? }
    .select { |r| File.exist?(File.join(PDFS_DIR, "#{r[:slug]}.pdf")) }

  if reports.size < SAMPLE_SIZE
    abort "Seulement #{reports.size} PDFs disponibles (besoin #{SAMPLE_SIZE})."
  end

  srand(RANDOM_SEED)
  reports.sample(SAMPLE_SIZE)
end

def targets_all
  unless File.exist?(VERIFIED_CSV)
    abort "#{VERIFIED_CSV} introuvable. Lance d'abord : ruby scripts/crc_validator.rb verify"
  end

  CSV.read(VERIFIED_CSV, headers: true)
    .select { |r| %w[high medium].include?(r['confidence']) && !r['siren'].to_s.empty? }
    .map { |r|
      slug = r['url'].split('/').last
      { url: r['url'], title: r['title'], slug: slug, siren: r['siren'] }
    }
    .reject { |t| t[:slug].empty? }
    .select { |t| File.exist?(File.join(PDFS_DIR, "#{t[:slug]}.pdf")) }
end

# ─── Bilan final ─────────────────────────────────────────────────────

def show_summary(mode)
  rows = CSV.read(AUDIT_CSV, headers: true)
  done = rows.count { |r| r['primary'] }

  puts ''
  puts '═══ Bilan ═══'
  puts ''
  puts "Rapports analysés avec succès : #{done}/#{rows.size}"

  if done.zero?
    puts 'Aucun rapport analysé.'
    return
  end

  puts ''
  primary_counts = Hash.new(0)
  rows.each { |r| primary_counts[r['primary'].to_s] += 1 if r['primary'] }
  puts 'Répartition des sujets principaux :'
  primary_counts.sort_by { |_, v| -v }.each do |k, v|
    pct = (100.0 * v / done).round(0)
    bar = '█' * (v.to_f / done * 20).round
    puts "  #{k.ljust(28)} #{v.to_s.rjust(2)}/#{done}  (#{pct.to_s.rjust(2)}%)  #{bar}"
  end

  fragile_strict = rows.count { |r| r['primary'] == 'fragilite_financiere' }
  fragile_broad  = rows.count { |r|
    r['primary'] == 'fragilite_financiere' ||
    r['categories'].to_s.include?('fragilite_financiere') ||
    %w[mentions_deficit mentions_fonds_propres_negatifs mentions_tresorerie_tendue].any? { |k| r[k] == 'true' }
  }
  rien_critique = rows.count { |r| r['primary'] == 'rien_critique' }

  puts ''
  puts "Vrais positifs (CRC conclut fragilité)         : #{fragile_strict}/#{done}  (#{(100.0 * fragile_strict / done).round}%)"
  puts "Vrais négatifs (CRC conclut rien critique)     : #{rien_critique}/#{done}  (#{(100.0 * rien_critique / done).round}%)"
  puts "Cas exploitables pour validation Vigil'Asso     : #{fragile_strict + rien_critique}/#{done}"

  if mode == :all
    pos_with_siren = rows.select { |r|
      r['primary'] == 'fragilite_financiere' && !r['siren'].to_s.empty?
    }
    neg_with_siren = rows.select { |r|
      r['primary'] == 'rien_critique' && !r['siren'].to_s.empty?
    }

    puts ''
    puts "─── Liste des SIREN exploitables pour la phase 3 ───"
    puts ''
    puts "Positifs attendus 'fragile' (#{pos_with_siren.size}) :"
    pos_with_siren.each { |r| puts "  #{r['siren']}  #{r['title'].slice(0, 60)}" }
    puts ''
    puts "Négatifs attendus 'sain' (#{neg_with_siren.size}) :"
    neg_with_siren.each { |r| puts "  #{r['siren']}  #{r['title'].slice(0, 60)}" }
    puts ''

    CSV.open(PHASE3_CSV, 'wb') do |out|
      out << %w[siren expected_label title url synthese]
      pos_with_siren.each { |r|
        out << [r['siren'], 'fragile', r['title'], r['url'], r['synthese']]
      }
      neg_with_siren.each { |r|
        out << [r['siren'], 'sain', r['title'], r['url'], r['synthese']]
      }
    end
    puts "  → #{PHASE3_CSV}"
    puts ''
    puts "Pour la phase 3, tu peux itérer sur ce fichier :"
    puts "  CSV.foreach('#{PHASE3_CSV}', headers: true) { |r| ... rake scrape_jo:run Q=#{'#'}{r['siren']} }"
  else
    ratio = fragile_broad.to_f / done
    puts ''
    puts "Extrapolation sur 116 SIREN haute confiance :"
    puts "  cas exploitables (strict, primary)        : ~#{(116.0 * fragile_strict / done).round}"
    puts "  cas exploitables (élargi, indicateurs)    : ~#{(116.0 * fragile_broad / done).round}"
    puts ''
    puts '─── Décision recommandée ───'
    if ratio >= 0.40
      puts '  ≥ 40%  →  Phase 3 vaut le coup, signal statistique solide.'
      puts '            Lance : ruby scripts/audit_pdfs.rb all'
    elsif ratio >= 0.15
      puts '  15-40% →  Phase 3 possible mais ajuste les attentes.'
      puts '            Si tu veux continuer : ruby scripts/audit_pdfs.rb all'
    else
      puts '  < 15%  →  Pivote, la donnée CRC ne sert pas la validation Vigil\'Asso.'
    end
  end

  puts ''
  puts "  → #{AUDIT_CSV}"
end

# ─── Main ────────────────────────────────────────────────────────────

mode = ARGV[0] == 'all' ? :all : :sample

unless ENV['ANTHROPIC_API_KEY']
  abort "ANTHROPIC_API_KEY manquante. Lance d'abord :\n  export $(grep -v '^#' .env | xargs)"
end

unless system('which pdftotext > /dev/null 2>&1')
  abort "pdftotext manquant. Installe : sudo apt install poppler-utils"
end

# Index SIREN par URL (utilisé pour enrichir le mode sample si verify a tourné)
siren_by_url = {}
if File.exist?(VERIFIED_CSV)
  CSV.foreach(VERIFIED_CSV, headers: true) do |r|
    siren_by_url[r['url']] = r['siren'] if r['siren'].to_s.size.positive?
  end
end

targets = mode == :all ? targets_all : targets_sample(siren_by_url)

# Resume : skip les URLs déjà dans le CSV
done_urls = Set.new
if File.exist?(AUDIT_CSV)
  CSV.foreach(AUDIT_CSV, headers: true) { |r| done_urls << r['url'] if r['primary'] }
end

remaining = targets.reject { |t| done_urls.include?(t[:url]) }

puts "[Audit qualitatif] mode=#{mode}"
puts "  cibles    : #{targets.size}"
puts "  déjà fait : #{targets.size - remaining.size}"
puts "  à faire   : #{remaining.size}"
puts "  modèle    : #{HAIKU_MODEL}"
puts ''

if remaining.empty?
  puts "Rien à faire. Affichage du bilan."
  show_summary(mode)
  exit 0
end

open_mode = File.exist?(AUDIT_CSV) ? 'ab' : 'wb'
CSV.open(AUDIT_CSV, open_mode) do |csv|
  if open_mode == 'wb'
    csv << %w[url title siren primary categories mentions_deficit
              mentions_fonds_propres_negatifs mentions_tresorerie_tendue
              mentions_dependance_subventions synthese]
  end

  remaining.each_with_index do |t, idx|
    print "  [#{idx + 1}/#{remaining.size}] #{t[:title].slice(0, 60)}… "
    pdf_path = File.join(PDFS_DIR, "#{t[:slug]}.pdf")
    text = extract_text(pdf_path)
    if text.nil?
      csv << [t[:url], t[:title], t[:siren], nil, nil, nil, nil, nil, nil, 'extraction PDF échouée']
      csv.flush
      puts 'PDF illisible'
      next
    end

    result = classify_report(t[:title], text)
    if result.nil?
      csv << [t[:url], t[:title], t[:siren], nil, nil, nil, nil, nil, nil, 'erreur Claude']
      csv.flush
      puts 'erreur Claude'
      next
    end

    cats = result['categories'] || []
    csv << [
      t[:url], t[:title], t[:siren],
      result['primary'], cats.join(';'),
      result['mentions_deficit'], result['mentions_fonds_propres_negatifs'],
      result['mentions_tresorerie_tendue'], result['mentions_dependance_subventions'],
      result['synthese']
    ]
    csv.flush
    puts "primary=#{result['primary']}"
    sleep 1.0
  end
end

show_summary(mode)
