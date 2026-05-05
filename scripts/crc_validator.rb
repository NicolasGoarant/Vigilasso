#!/usr/bin/env ruby
# scripts/crc_validator.rb — v5
#
# Sous-commandes :
#   pdfs              télécharge les 162 PDFs CRC
#   match             matching automatique par scoring (legacy v4, gardé pour debug)
#   verify            vérification Claude Haiku — chaque rapport relit ses 5
#                     meilleurs candidats SIRENE et l'arbitre tranche
#   sirens_stats      bilan du match
#   verified_stats    bilan du verify
#   debug "TITRE..."  audit d'un cas
#
# v5 : nouvelle commande verify qui remplace match/scoring fuzzy par un appel
# Haiku qui arbitre entre les 5 candidats de l'API gouv pour chaque rapport.
# Bien plus fiable parce que Haiku comprend les sigles, les régions, les
# secteurs d'activité et sait dire "aucun" quand rien ne correspond.

require 'csv'
require 'json'
require 'net/http'
require 'set'
require 'uri'
require 'fileutils'

PROJECT_ROOT = File.expand_path('..', __dir__)
DATA_DIR     = File.join(PROJECT_ROOT, 'app/assets/fichiers_internes/data')
REPORTS_CSV  = File.join(DATA_DIR, 'reports.csv')
PDFS_DIR     = File.join(DATA_DIR, 'crc_pdfs')
SIRENS_CSV   = File.join(DATA_DIR, 'sirens.csv')
VERIFIED_CSV = File.join(DATA_DIR, 'sirens_verified.csv')

API_URL = 'https://recherche-entreprises.api.gouv.fr/search'
NATURE_JURIDIQUE_OK = %w[9220 9221 9222 9223 9224 9230 9240 9260 9300]

ANTHROPIC_API_URL = 'https://api.anthropic.com/v1/messages'
HAIKU_MODEL       = 'claude-haiku-4-5-20251001'

SCORE_MIN   = 0.30
TOP2_MARGIN = 0.10
HTTP_DELAY  = 0.3

THEMATIC_PATTERNS = [
  /\AAssociations? gestionnaires? du/i,
  /\benqu[êe]te (xynthia|protection de l['']enfant|maintien.+domicile|musique et culture|politique.+tourisme|r[ée]gionale.+propret[ée]|sur les politiques)/i,
  /\Asuivi des recommandations/i,
  /\bcomptes d['']emploi (pour|à compter|\d{4})/i,
  /\Aassociations? union interprofession/i
]

STOPWORDS = %w[
  a au aux à association associations fondation de des du d en et l la le les
  un une pour par sur sous dans avec sans selon ses son sa ce cette
].to_set

SIGLE_BLACKLIST = %w[
  CRC CRTC ROD CDC CRT CCR ASA AFR APE NAF SAS SARL EURL
  EHPAD ESAT IME IMP MJC SDIS UNESCO ONG LGV TGV SNCF
  SIREN SIRET RNA RIB IBAN
].to_set

def thematic_report?(title)
  THEMATIC_PATTERNS.any? { |re| title =~ re }
end

def strip_accents(s)
  s.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, '')
end

def tokenize(s)
  strip_accents(s)
    .downcase
    .gsub(/[^a-z0-9 ]/, ' ')
    .split
    .reject { |w| w.length < 2 || STOPWORDS.include?(w) }
end

def clean_query(title)
  title.to_s
    .sub(/\A(?:Associations?|Fondation)s?\s+/i, '')
    .gsub(/[«»""'']/, '')
    .gsub(/\s*\([^)]*\)\s*/, ' ')
    .gsub(/\s+-\s+.*\z/, '')
    .gsub(/,.*\z/, '')
    .squeeze(' ')
    .strip
end

def candidate_sigles(title)
  explicit_paren  = title.scan(/\(([A-Z][A-Z0-9'\- ]{1,9}[A-Z0-9])\)/).flatten
  explicit_inline = title.scan(/\b([A-Z]{3,7})\b/).flatten
  cleaned_first = tokenize(clean_query(title)).first
  implicit = []
  if cleaned_first && cleaned_first.length.between?(4, 8)
    implicit << cleaned_first.upcase
  end
  (explicit_paren + explicit_inline + implicit)
    .uniq
    .reject { |s| SIGLE_BLACKLIST.include?(s) }
    .reject { |s| s.length < 3 }
end

DEPARTEMENT_MAP = {
  /\bain\b/i => '01', /\baisne\b/i => '02', /\ballier\b/i => '03',
  /\balpes[\- ]de[\- ]haute[\- ]provence\b/i => '04',
  /\bhautes[\- ]alpes\b/i => '05', /\balpes[\- ]maritimes\b/i => '06',
  /\bard[èe]che\b/i => '07', /\bardennes\b/i => '08',
  /\bari[èe]ge\b/i => '09', /\baube\b/i => '10', /\baude\b/i => '11',
  /\baveyron\b/i => '12', /\bbouches[\- ]du[\- ]rh[ôo]ne\b/i => '13',
  /\bcalvados\b/i => '14', /\bcantal\b/i => '15',
  /\bcharente[\- ]maritime\b/i => '17', /\bcharente\b/i => '16',
  /\bcher\b/i => '18', /\bcorr[èe]ze\b/i => '19',
  /\bcorse[\- ]du[\- ]sud\b/i => '2A', /\bhaute[\- ]corse\b/i => '2B',
  /\bc[ôo]te[\- ]d[''\s]or\b/i => '21',
  /\bc[ôo]tes[\- ]d[''\s]armor\b/i => '22',
  /\bcreuse\b/i => '23', /\bdordogne\b/i => '24', /\bdoubs\b/i => '25',
  /\bdr[ôo]me\b/i => '26',
  /\beure[\- ]et[\- ]loir\b/i => '28', /\beure\b/i => '27',
  /\bfinist[èe]re\b/i => '29',
  /\bgard\b/i => '30', /\bhaute[\- ]garonne\b/i => '31',
  /\bgers\b/i => '32', /\bgironde\b/i => '33', /\bh[ée]rault\b/i => '34',
  /\bille[\- ]et[\- ]vilaine\b/i => '35',
  /\bindre[\- ]et[\- ]loire\b/i => '37', /\bindre\b/i => '36',
  /\bis[èe]re\b/i => '38', /\bjura\b/i => '39', /\blandes\b/i => '40',
  /\bloir[\- ]et[\- ]cher\b/i => '41', /\bloire[\- ]atlantique\b/i => '44',
  /\bhaute[\- ]loire\b/i => '43', /\bloiret\b/i => '45',
  /\bloire\b/i => '42',
  /\blot[\- ]et[\- ]garonne\b/i => '47', /\blot\b/i => '46',
  /\bloz[èe]re\b/i => '48',
  /\bmaine[\- ]et[\- ]loire\b/i => '49', /\bmanche\b/i => '50',
  /\bhaute[\- ]marne\b/i => '52', /\bmarne\b/i => '51',
  /\bmayenne\b/i => '53', /\bmeurthe[\- ]et[\- ]moselle\b/i => '54',
  /\bmeuse\b/i => '55', /\bmorbihan\b/i => '56', /\bmoselle\b/i => '57',
  /\bni[èe]vre\b/i => '58', /\bnord\b/i => '59',
  /\boise\b/i => '60', /\borne\b/i => '61',
  /\bpas[\- ]de[\- ]calais\b/i => '62', /\bpuy[\- ]de[\- ]d[ôo]me\b/i => '63',
  /\bpyr[ée]n[ée]es[\- ]atlantiques\b/i => '64',
  /\bhautes[\- ]pyr[ée]n[ée]es\b/i => '65',
  /\bpyr[ée]n[ée]es[\- ]orientales\b/i => '66',
  /\bbas[\- ]rhin\b/i => '67', /\bhaut[\- ]rhin\b/i => '68',
  /\bm[ée]tropole de lyon\b/i => '69', /\brh[ôo]ne\b/i => '69',
  /\bhaute[\- ]sa[ôo]ne\b/i => '70',
  /\bsa[ôo]ne[\- ]et[\- ]loire\b/i => '71', /\bsarthe\b/i => '72',
  /\bhaute[\- ]savoie\b/i => '74', /\bsavoie\b/i => '73',
  /\bparis\b/i => '75', /\bseine[\- ]maritime\b/i => '76',
  /\bseine[\- ]et[\- ]marne\b/i => '77', /\byvelines\b/i => '78',
  /\bdeux[\- ]s[èe]vres\b/i => '79', /\bsomme\b/i => '80',
  /\btarn[\- ]et[\- ]garonne\b/i => '82', /\btarn\b/i => '81',
  /\bvar\b/i => '83', /\bvaucluse\b/i => '84', /\bvend[ée]e\b/i => '85',
  /\bhaute[\- ]vienne\b/i => '87', /\bvienne\b/i => '86',
  /\bvosges\b/i => '88', /\byonne\b/i => '89',
  /\bterritoire[\- ]de[\- ]belfort\b/i => '90', /\bessonne\b/i => '91',
  /\bhauts[\- ]de[\- ]seine\b/i => '92',
  /\bseine[\- ]saint[\- ]denis\b/i => '93',
  /\bval[\- ]de[\- ]marne\b/i => '94', /\bval[\- ]d[''\s]oise\b/i => '95',
  /\bguadeloupe\b/i => '971', /\bmartinique\b/i => '972',
  /\bguyane\b/i => '973', /\b(?:la )?r[ée]union\b/i => '974',
  /\bmayotte\b/i => '976'
}

def dept_from_title(title)
  DEPARTEMENT_MAP.each { |re, code| return code if title =~ re }
  nil
end

def query_variants(title, sigles)
  cleaned = clean_query(title)
  cleaned_words = tokenize(cleaned)
  variants = []
  variants << cleaned_words.first(6).join(' ') if cleaned_words.any?
  sigles.each do |sigle|
    variants << sigle
    distinctive = cleaned_words.find { |w| w.length >= 4 && w.upcase != sigle.upcase }
    variants << "#{sigle} #{distinctive}" if distinctive
  end
  variants << cleaned_words.first(3).join(' ') if cleaned_words.size >= 2
  variants.uniq.compact.reject(&:empty?)
end

def score_match(query_title, sigles, candidate_name)
  q = tokenize(query_title).to_set
  c = tokenize(candidate_name).to_set
  return 0.0 if c.empty? || q.empty?
  inter = (q & c).size.to_f
  return 0.0 if inter.zero?
  recall    = inter / q.size
  precision = inter / c.size
  f1 = 2 * recall * precision / (recall + precision)
  cand_upper = candidate_name.upcase
  if sigles.any? { |s| cand_upper =~ /\b#{Regexp.escape(s.upcase)}\b/ }
    f1 += 0.25
  end
  extra = (c - q).reject { |w| w.length < 4 }
  f1 -= 0.10 if extra.size >= 2
  [[f1, 0.0].max, 1.0].min
end

def api_search(query, departement = nil, with_nj_filter: true)
  parts = [
    "q=#{URI.encode_www_form_component(query)}",
    'per_page=10'
  ]
  parts << "nature_juridique=#{NATURE_JURIDIQUE_OK.join(',')}" if with_nj_filter
  parts << "departement=#{departement}" if departement
  uri = URI("#{API_URL}?#{parts.join('&')}")
  res = Net::HTTP.get_response(uri)
  return [] unless res.code == '200'
  JSON.parse(res.body)['results'] || []
rescue StandardError => e
  warn "  ⚠ API gouv : #{e.message}"
  []
end

# ─── cmd_pdfs ────────────────────────────────────────────────────────

def cmd_pdfs
  FileUtils.mkdir_p(PDFS_DIR)
  reports = CSV.read(REPORTS_CSV, headers: true).select { |r|
    r['is_loi_1901'] == 'true' && r['pdf_url'].to_s.size.positive?
  }
  puts "[Phase 1] Téléchargement de #{reports.size} PDFs CRC…"
  total = downloaded = cached = failed = 0
  reports.each do |row|
    total += 1
    slug = row['url'].split('/').last
    out  = File.join(PDFS_DIR, "#{slug}.pdf")
    if File.exist?(out)
      cached += 1
      next
    end
    print "  [#{total}/#{reports.size}] #{slug}… "
    begin
      uri = URI(row['pdf_url'])
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        resp = http.get(uri.request_uri, 'User-Agent' => 'VigilAssoBot/0.1')
        if resp.code == '200'
          File.write(out, resp.body, mode: 'wb')
          puts "#{(resp.body.size / 1024.0).round} Ko"
          downloaded += 1
        else
          puts "HTTP #{resp.code}"
          failed += 1
        end
      end
    rescue StandardError => e
      puts "ERR : #{e.message}"
      failed += 1
    end
    sleep 0.5
  end
  puts ''
  puts "Téléchargés : #{downloaded}  Cache : #{cached}  Échecs : #{failed}"
end

# ─── cmd_match (legacy v4) ───────────────────────────────────────────

def cmd_match
  reports = CSV.read(REPORTS_CSV, headers: true).select { |r| r['is_loi_1901'] == 'true' }
  done_uris = Set.new
  if File.exist?(SIRENS_CSV)
    CSV.foreach(SIRENS_CSV, headers: true) { |r| done_uris << r['url'] }
    puts "  (#{done_uris.size} déjà traités — reprise)"
  end
  mode = File.exist?(SIRENS_CSV) ? 'ab' : 'wb'
  CSV.open(SIRENS_CSV, mode) do |csv|
    if mode == 'wb'
      csv << %w[url title siren canonical_name nature_juridique
                score ambiguous thematic departement query_used nb_candidates]
    end
    puts "[Phase 2 v4] Matching SIREN par scoring (legacy)…"
    reports.each_with_index do |row, idx|
      next if done_uris.include?(row['url'])
      title = row['title']
      print "  [#{idx + 1}/#{reports.size}] #{title.slice(0, 68)}… "
      if thematic_report?(title)
        csv << [row['url'], title, nil, nil, nil, nil, false, true, nil, nil, 0]
        csv.flush
        puts 'rapport thématique (skip)'
        next
      end
      sigles   = candidate_sigles(title)
      dept     = dept_from_title(title)
      variants = query_variants(title, sigles)
      all_candidates = {}
      variants.each do |variant|
        sleep HTTP_DELAY
        api_search(variant, dept).each do |r|
          siren = r['siren']
          s = score_match(title, sigles, r['nom_complet'])
          if !all_candidates[siren] || all_candidates[siren][:score] < s
            all_candidates[siren] = { row: r, score: s, variant: variant }
          end
        end
      end
      if all_candidates.empty?
        csv << [row['url'], title, nil, nil, nil, nil, false, false, dept, variants.first, 0]
        csv.flush
        puts 'aucun résultat API'
        next
      end
      sorted = all_candidates.values.sort_by { |c| -c[:score] }
      best = sorted.first
      if best[:score] < SCORE_MIN
        csv << [row['url'], title, nil, nil, nil, format('%.3f', best[:score]),
                false, false, dept, best[:variant], all_candidates.size]
        csv.flush
        puts "aucun match fiable (best=#{best[:row]['nom_complet'].slice(0, 30)} score=#{best[:score].round(2)})"
        next
      end
      ambiguous = sorted.size >= 2 && (sorted[0][:score] - sorted[1][:score]) < TOP2_MARGIN
      csv << [
        row['url'], title,
        best[:row]['siren'], best[:row]['nom_complet'], best[:row]['nature_juridique'],
        format('%.3f', best[:score]), ambiguous, false, dept,
        best[:variant], all_candidates.size
      ]
      csv.flush
      tag = ambiguous ? '⚠ ambigu' : '✓'
      puts "#{tag} #{best[:row]['siren']} (#{best[:row]['nom_complet'].slice(0, 50)}, score #{best[:score].round(2)})"
    end
  end
  puts ''
  puts "  → #{SIRENS_CSV}"
end

def cmd_sirens_stats
  unless File.exist?(SIRENS_CSV)
    puts "Pas de #{SIRENS_CSV}, lance 'match' d'abord."
    return
  end
  rows = CSV.read(SIRENS_CSV, headers: true)
  total      = rows.size
  thematic   = rows.count { |r| r['thematic'].to_s == 'true' }
  with_siren = rows.count { |r| !r['siren'].to_s.empty? }
  high_conf  = rows.count { |r|
    !r['siren'].to_s.empty? && r['ambiguous'].to_s != 'true' && r['score'].to_f >= 0.5
  }
  ambiguous  = rows.count { |r| r['ambiguous'].to_s == 'true' }
  no_match   = rows.count { |r| r['siren'].to_s.empty? && r['thematic'].to_s != 'true' }
  puts "Rapports analysés        : #{total}"
  puts "  thématiques (skip)     : #{thematic}"
  puts "SIREN trouvés            : #{with_siren}"
  puts "  haute confiance        : #{high_conf}"
  puts "  ambigus                : #{ambiguous}"
  puts "Sans SIREN               : #{no_match}"
end

# ─── cmd_verify (NOUVEAU v5) ─────────────────────────────────────────

def find_candidates_for_verify(title)
  dept = dept_from_title(title)
  cleaned = clean_query(title)
  short_query = tokenize(cleaned).first(5).join(' ')
  return [] if short_query.empty?

  # Stratégie 1 : nature_juridique 9XXX + département
  sleep HTTP_DELAY
  results = api_search(short_query, dept, with_nj_filter: true)
  return results.first(5) if results.any?

  # Stratégie 2 : sans département (assos régionales, anciens noms…)
  sleep HTTP_DELAY
  results = api_search(short_query, nil, with_nj_filter: true)
  return results.first(5) if results.any?

  # Stratégie 3 : query plus courte avec dept
  shorter = tokenize(cleaned).first(3).join(' ')
  if shorter != short_query
    sleep HTTP_DELAY
    results = api_search(shorter, dept, with_nj_filter: true)
    return results.first(5) if results.any?
  end

  # Stratégie 4 : sigle seul + dept
  sigles = candidate_sigles(title)
  if sigles.any?
    sleep HTTP_DELAY
    results = api_search(sigles.first, dept, with_nj_filter: true)
    return results.first(5) if results.any?
  end

  []
end

def format_candidate(c, num)
  siege = c['siege'] || {}
  parts = ["(#{num}) SIREN #{c['siren']} — #{c['nom_complet']}"]
  parts.last << " (sigle: #{c['sigle']})" if c['sigle'].to_s.size.positive?
  loc = [siege['commune'], siege['code_postal']].compact.join(' ')
  parts << "    siège : #{loc}" unless loc.empty?
  ape = siege['activite_principale'].to_s
  parts << "    APE : #{ape}" unless ape.empty?
  parts << "    créée : #{siege['date_creation']}" if siege['date_creation']
  parts.join("\n")
end

def claude_identify(report_title, candidates)
  cands_text = candidates.each_with_index.map { |c, i| format_candidate(c, i + 1) }.join("\n\n")
  none_num = candidates.size + 1

  prompt = <<~PROMPT
    Tu reçois le titre d'un rapport d'une chambre régionale des comptes (ou de la Cour des comptes) portant sur UNE association loi 1901 ou UNE fondation. Ensuite tu reçois une liste de candidats trouvés dans la base SIRENE. Identifie celui qui correspond au rapport.

    Critères : nom (incluant sigles, anciens noms, raison sociale), localisation (département, commune), nature de l'activité (code APE cohérent avec ce que fait l'asso).

    Sois conservateur : si AUCUN candidat ne correspond clairement, réponds #{none_num} (aucun). Mieux vaut un "aucun" qu'un faux positif.

    TITRE DU RAPPORT :
    #{report_title}

    CANDIDATS :
    #{cands_text}

    (#{none_num}) Aucun de ces candidats ne correspond

    Réponds UNIQUEMENT par un objet JSON valide sur UNE seule ligne, sans aucun autre texte :
    {"choice": <entier de 1 à #{none_num}>, "confidence": "high"|"medium"|"low", "reason": "<une phrase courte en français>"}
  PROMPT

  uri = URI(ANTHROPIC_API_URL)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 30

  req = Net::HTTP::Post.new(uri.request_uri)
  req['x-api-key'] = ENV.fetch('ANTHROPIC_API_KEY')
  req['anthropic-version'] = '2023-06-01'
  req['content-type'] = 'application/json'
  req.body = {
    model: HAIKU_MODEL,
    max_tokens: 250,
    messages: [{ role: 'user', content: prompt }]
  }.to_json

  resp = http.request(req)

  if resp.code == '429'
    warn "  ⏳ rate limit, sleep 30s"
    sleep 30
    return claude_identify(report_title, candidates)
  end

  unless resp.code == '200'
    warn "  ⚠ HTTP #{resp.code} : #{resp.body.to_s[0, 200]}"
    return nil
  end

  data = JSON.parse(resp.body)
  text = data.dig('content', 0, 'text').to_s.strip
  if text =~ /(\{.*?\})/m
    JSON.parse(Regexp.last_match(1))
  end
rescue StandardError => e
  warn "  ⚠ Erreur Claude : #{e.message}"
  nil
end

def cmd_verify
  unless ENV['ANTHROPIC_API_KEY']
    abort "ANTHROPIC_API_KEY manquante. Lance d'abord :\n  export $(grep -v '^#' .env | xargs)"
  end

  reports = CSV.read(REPORTS_CSV, headers: true).select { |r| r['is_loi_1901'] == 'true' }

  done_uris = Set.new
  if File.exist?(VERIFIED_CSV)
    CSV.foreach(VERIFIED_CSV, headers: true) { |r| done_uris << r['url'] }
    puts "  (#{done_uris.size} déjà vérifiés — reprise)"
  end

  mode = File.exist?(VERIFIED_CSV) ? 'ab' : 'wb'
  CSV.open(VERIFIED_CSV, mode) do |csv|
    if mode == 'wb'
      csv << %w[url title siren canonical_name nature_juridique commune
                confidence reason thematic nb_candidates]
    end

    puts "[Phase 2 v5] Vérification par Claude Haiku pour #{reports.size} rapports…"
    puts "  modèle : #{HAIKU_MODEL}"
    puts ''

    reports.each_with_index do |row, idx|
      next if done_uris.include?(row['url'])

      title = row['title']
      print "  [#{idx + 1}/#{reports.size}] #{title.slice(0, 60)}… "

      if thematic_report?(title)
        csv << [row['url'], title, nil, nil, nil, nil, nil, 'rapport thématique', true, 0]
        csv.flush
        puts 'thématique'
        next
      end

      candidates = find_candidates_for_verify(title)
      if candidates.empty?
        csv << [row['url'], title, nil, nil, nil, nil, 'low', 'aucun candidat trouvé dans SIRENE', false, 0]
        csv.flush
        puts 'aucun candidat'
        next
      end

      result = claude_identify(title, candidates)
      if result.nil?
        csv << [row['url'], title, nil, nil, nil, nil, nil, 'erreur Claude', false, candidates.size]
        csv.flush
        puts 'erreur Claude'
        sleep 1
        next
      end

      choice = result['choice'].to_i
      conf   = result['confidence'].to_s
      reason = result['reason'].to_s

      if choice < 1 || choice > candidates.size
        csv << [row['url'], title, nil, nil, nil, nil, conf, reason, false, candidates.size]
        csv.flush
        puts "aucun (#{conf}) : #{reason.slice(0, 50)}"
      else
        chosen = candidates[choice - 1]
        siege = chosen['siege'] || {}
        csv << [
          row['url'], title,
          chosen['siren'], chosen['nom_complet'], chosen['nature_juridique'],
          siege['commune'], conf, reason, false, candidates.size
        ]
        csv.flush
        tag = case conf
              when 'high'   then '✓'
              when 'medium' then '~'
              else '?'
              end
        puts "#{tag} #{chosen['siren']} #{conf} #{chosen['nom_complet'].slice(0, 40)}"
      end

      sleep 0.7 # rate limit safety pour Haiku
    end
  end

  puts ''
  puts "  → #{VERIFIED_CSV}"
end

def cmd_verified_stats
  unless File.exist?(VERIFIED_CSV)
    puts "Pas de #{VERIFIED_CSV}, lance 'verify' d'abord."
    return
  end
  rows = CSV.read(VERIFIED_CSV, headers: true)
  total      = rows.size
  thematic   = rows.count { |r| r['thematic'] == 'true' }
  with_siren = rows.count { |r| !r['siren'].to_s.empty? }
  high       = rows.count { |r| r['confidence'] == 'high' && !r['siren'].to_s.empty? }
  medium     = rows.count { |r| r['confidence'] == 'medium' && !r['siren'].to_s.empty? }
  low        = rows.count { |r| r['confidence'] == 'low' && !r['siren'].to_s.empty? }
  no_match   = rows.count { |r| r['siren'].to_s.empty? && r['thematic'] != 'true' }

  puts "Rapports vérifiés        : #{total}"
  puts "  thématiques (skip)     : #{thematic}"
  puts "SIREN identifiés         : #{with_siren}"
  puts "  confiance high         : #{high}    ← utilisable directement"
  puts "  confiance medium       : #{medium}    ← à survoler"
  puts "  confiance low          : #{low}    ← douteux"
  puts "Rapports sans SIREN      : #{no_match}"
  puts ''
  puts 'Échantillon des 15 premiers :'
  rows.first(15).each do |r|
    siren = r['siren'].to_s.empty? ? '(absent)  ' : r['siren']
    conf  = r['confidence'].to_s.ljust(6)
    name  = r['canonical_name'].to_s.slice(0, 45)
    flag = r['thematic'] == 'true' ? 'T' : ' '
    puts "  #{siren} #{conf} #{flag} #{name}"
  end
end

def cmd_debug(title)
  puts "Titre        : #{title}"
  puts "Thématique ? : #{thematic_report?(title)}"
  sigles = candidate_sigles(title)
  puts "Sigles       : #{sigles.inspect}"
  dept = dept_from_title(title)
  puts "Département  : #{dept}"
  variants = query_variants(title, sigles)
  puts 'Variantes    :'
  variants.each_with_index { |v, i| puts "  [#{i + 1}] #{v}" }
  puts ''
  puts 'Candidats find_candidates_for_verify :'
  candidates = find_candidates_for_verify(title)
  candidates.each_with_index do |c, i|
    puts format_candidate(c, i + 1)
  end
end

case ARGV[0]
when 'pdfs'           then cmd_pdfs
when 'match'          then cmd_match
when 'verify'         then cmd_verify
when 'sirens_stats'   then cmd_sirens_stats
when 'verified_stats' then cmd_verified_stats
when 'debug'          then cmd_debug(ARGV[1].to_s)
else
  puts "Usage : ruby scripts/crc_validator.rb {pdfs|match|verify|sirens_stats|verified_stats|debug 'TITRE'}"
end
