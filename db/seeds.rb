if User.where(email: "admin@vigilasso.fr").none?
  User.create!(
    email: "admin@vigilasso.fr",
    password: "changeme123",
    name: "Admin Test",
    organisation: "Vigil'Asso"
  )
  puts "Vigil'Asso seed — utilisateur de test créé : admin@vigilasso.fr / changeme123"
else
  puts "Vigil'Asso seed — admin@vigilasso.fr existe déjà"
end
