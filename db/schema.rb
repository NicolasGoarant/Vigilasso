# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2026_05_01_170926) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "associations", force: :cascade do |t|
    t.string "siren"
    t.string "nom"
    t.string "ville"
    t.date "cloture"
    t.integer "total_produits"
    t.integer "resultat_exploitation"
    t.integer "resultat_net"
    t.integer "fonds_propres"
    t.integer "tresorerie"
    t.integer "emprunts"
    t.integer "total_bilan"
    t.integer "subv_sur_produits_pct"
    t.integer "masse_sal_pct"
    t.integer "fp_bilan_pct"
    t.decimal "etp"
    t.boolean "cac_certifie"
    t.integer "statut"
    t.text "notes"
    t.jsonb "extraction_raw"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "score_vigi"
    t.string "niveau_vigi", limit: 1
    t.jsonb "score_detail"
    t.boolean "defaillance_bodacc"
    t.date "date_jugement"
    t.string "nature_jugement"
    t.index ["siren", "cloture"], name: "index_associations_on_siren_and_cloture", unique: true
  end

  create_table "compte_annuels", force: :cascade do |t|
    t.string "siren"
    t.string "jo_id"
    t.date "date_cloture"
    t.integer "exercice"
    t.string "pdf_path"
    t.string "statut"
    t.integer "total_bilan"
    t.integer "total_actif_immobilise"
    t.integer "total_actif_circulant"
    t.integer "fonds_propres"
    t.integer "dettes_total"
    t.integer "provisions"
    t.integer "produits_exploitation"
    t.integer "charges_exploitation"
    t.integer "resultat_exploitation"
    t.integer "produits_financiers"
    t.integer "charges_financieres"
    t.integer "resultat_financier"
    t.integer "resultat_exceptionnel"
    t.integer "resultat_net"
    t.integer "subventions"
    t.integer "masse_salariale"
    t.integer "charges_sociales"
    t.decimal "effectif_etp"
    t.text "raw_json"
    t.text "erreur"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
end
