namespace :analyses do
  desc "Supprime les analyses anonymes expirées (expires_at IS NOT NULL AND expires_at < now)"
  task purge: :environment do
    expired = Analysis.where("expires_at IS NOT NULL AND expires_at < ?", Time.now)
    count = expired.count
    expired.destroy_all
    puts "Supprimées : #{count} analyses expirées"
  end
end
