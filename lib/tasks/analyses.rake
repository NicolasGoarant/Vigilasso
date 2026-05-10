namespace :analyses do
  desc "Supprime les analyses anonymes expirées (expires_at < now)"
  task purge: :environment do
    n = Analysis.expirees.count
    Analysis.expirees.delete_all
    puts "Vigil'Asso analyses:purge — #{n} analyse(s) supprimée(s)."
  end
end
