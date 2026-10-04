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

ActiveRecord::Schema[8.1].define(version: 2026_10_04_170000) do
  create_table "api_keys", force: :cascade do |t|
    t.bigint "bearer_id", null: false
    t.string "bearer_type", null: false
    t.string "common_token_prefix", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "random_token_prefix", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["bearer_type", "bearer_id"], name: "index_api_keys_on_bearer"
    t.index ["token_digest"], name: "index_api_keys_on_token_digest", unique: true
  end

  create_table "context_memberships", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "context_id", null: false
    t.datetime "created_at", null: false
    t.integer "mcp_server_id", null: false
    t.datetime "updated_at", null: false
    t.index ["context_id", "mcp_server_id"], name: "index_context_memberships_on_context_id_and_mcp_server_id", unique: true
    t.index ["context_id"], name: "index_context_memberships_on_context_id"
    t.index ["mcp_server_id"], name: "index_context_memberships_on_mcp_server_id"
    t.check_constraint "context_id <> mcp_server_id", name: "context_memberships_no_self"
  end

  create_table "invitations", force: :cascade do |t|
    t.string "code", null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.string "signature", null: false
    t.string "state", default: "created", null: false
    t.datetime "updated_at", null: false
    t.datetime "valid_from", null: false
    t.datetime "valid_to", null: false
    t.index ["code"], name: "index_invitations_on_code", unique: true
    t.index ["signature"], name: "index_invitations_on_signature", unique: true
    t.index ["state"], name: "index_invitations_on_state"
  end

  create_table "mcp_oauth_access_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "mcp_oauth_client_id", null: false
    t.bigint "mcp_server_id", null: false
    t.string "scope"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["mcp_oauth_client_id"], name: "index_mcp_oauth_access_tokens_on_mcp_oauth_client_id"
    t.index ["mcp_server_id"], name: "index_mcp_oauth_access_tokens_on_mcp_server_id"
    t.index ["token"], name: "index_mcp_oauth_access_tokens_on_token", unique: true
  end

  create_table "mcp_oauth_auth_codes", force: :cascade do |t|
    t.string "code", null: false
    t.string "code_challenge", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "mcp_oauth_client_id", null: false
    t.bigint "mcp_server_id", null: false
    t.string "redirect_uri", null: false
    t.string "scope"
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_mcp_oauth_auth_codes_on_code", unique: true
    t.index ["mcp_oauth_client_id"], name: "index_mcp_oauth_auth_codes_on_mcp_oauth_client_id"
    t.index ["mcp_server_id"], name: "index_mcp_oauth_auth_codes_on_mcp_server_id"
  end

  create_table "mcp_oauth_clients", force: :cascade do |t|
    t.string "client_id", null: false
    t.integer "client_id_issued_at", null: false
    t.string "client_name"
    t.string "client_secret"
    t.integer "client_secret_expires_at", default: 0, null: false
    t.datetime "created_at", null: false
    t.json "grant_types", default: [], null: false
    t.bigint "mcp_server_id", null: false
    t.json "redirect_uris", default: [], null: false
    t.json "response_types", default: [], null: false
    t.string "scope"
    t.string "token_endpoint_auth_method", default: "client_secret_post", null: false
    t.datetime "updated_at", null: false
    t.index ["client_id"], name: "index_mcp_oauth_clients_on_client_id", unique: true
    t.index ["mcp_server_id"], name: "index_mcp_oauth_clients_on_mcp_server_id"
  end

  create_table "mcp_oauth_login_states", force: :cascade do |t|
    t.string "client_id", null: false
    t.string "client_state"
    t.string "code_challenge", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "mcp_server_id", null: false
    t.string "redirect_uri", null: false
    t.string "scope"
    t.string "state", null: false
    t.datetime "updated_at", null: false
    t.index ["mcp_server_id"], name: "index_mcp_oauth_login_states_on_mcp_server_id"
    t.index ["state"], name: "index_mcp_oauth_login_states_on_state", unique: true
  end

  create_table "mcp_oauth_refresh_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "mcp_oauth_client_id", null: false
    t.bigint "mcp_server_id", null: false
    t.string "scope"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["mcp_oauth_client_id"], name: "index_mcp_oauth_refresh_tokens_on_mcp_oauth_client_id"
    t.index ["mcp_server_id"], name: "index_mcp_oauth_refresh_tokens_on_mcp_server_id"
    t.index ["token"], name: "index_mcp_oauth_refresh_tokens_on_token", unique: true
  end

  create_table "mcp_provider_oauth_states", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "mcp_server_id", null: false
    t.json "payload", default: {}, null: false
    t.string "state", null: false
    t.datetime "updated_at", null: false
    t.index ["mcp_server_id"], name: "index_mcp_provider_oauth_states_on_mcp_server_id"
    t.index ["state"], name: "index_mcp_provider_oauth_states_on_state", unique: true
  end

  create_table "mcp_server_types", force: :cascade do |t|
    t.boolean "allow_write", default: false, null: false
    t.string "class_name", null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.text "description", default: "", null: false
    t.string "name", null: false
    t.boolean "oauth_token_retrieval", default: false, null: false
    t.integer "service_token_refresh_in_minutes"
    t.integer "token_refresh_in_minutes"
    t.datetime "updated_at", null: false
    t.string "version", default: "0.1.0", null: false
    t.index ["class_name"], name: "index_mcp_server_types_on_class_name", unique: true
    t.index ["code"], name: "index_mcp_server_types_on_code", unique: true
  end

  create_table "mcp_servers", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.boolean "allow_write", default: false, null: false
    t.datetime "created_at", null: false
    t.text "credentials"
    t.text "description", default: "", null: false
    t.integer "mcp_server_type_id", null: false
    t.string "name", null: false
    t.text "oauth_token_payload"
    t.integer "service_token_refresh_in_minutes"
    t.integer "token_refresh_in_minutes"
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["mcp_server_type_id"], name: "index_mcp_servers_on_mcp_server_type_id"
    t.index ["type"], name: "index_mcp_servers_on_type"
    t.index ["user_id"], name: "index_mcp_servers_on_user_id"
  end

  create_table "plan_types", force: :cascade do |t|
    t.string "code"
    t.datetime "created_at", null: false
    t.integer "days"
    t.text "description"
    t.boolean "is_active"
    t.boolean "is_default"
    t.string "name"
    t.decimal "price", precision: 10, scale: 2
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_plan_types_on_code", unique: true
  end

  create_table "plans", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "plan_type_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.date "valid_from"
    t.date "valid_to"
    t.index ["plan_type_id"], name: "index_plans_on_plan_type_id"
    t.index ["user_id"], name: "index_plans_on_user_id"
  end

  create_table "roles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.bigint "resource_id"
    t.string "resource_type"
    t.datetime "updated_at", null: false
    t.index ["name", "resource_type", "resource_id"], name: "index_roles_on_name_and_resource_type_and_resource_id"
    t.index ["resource_type", "resource_id"], name: "index_roles_on_resource"
  end

  create_table "taggings", force: :cascade do |t|
    t.string "context", limit: 128
    t.datetime "created_at"
    t.integer "tag_id"
    t.integer "taggable_id"
    t.string "taggable_type"
    t.integer "tagger_id"
    t.string "tagger_type"
    t.string "tenant", limit: 128
    t.index ["context"], name: "index_taggings_on_context"
    t.index ["tag_id", "taggable_id", "taggable_type", "context", "tagger_id", "tagger_type"], name: "taggings_idx", unique: true
    t.index ["tag_id"], name: "index_taggings_on_tag_id"
    t.index ["taggable_id", "taggable_type", "context"], name: "taggings_taggable_context_idx"
    t.index ["taggable_id", "taggable_type", "tagger_id", "context"], name: "taggings_idy"
    t.index ["taggable_id"], name: "index_taggings_on_taggable_id"
    t.index ["taggable_type", "taggable_id"], name: "index_taggings_on_taggable"
    t.index ["taggable_type"], name: "index_taggings_on_taggable_type"
    t.index ["tagger_id", "tagger_type"], name: "index_taggings_on_tagger_id_and_tagger_type"
    t.index ["tagger_id"], name: "index_taggings_on_tagger_id"
    t.index ["tagger_type", "tagger_id"], name: "index_taggings_on_tagger"
    t.index ["tenant"], name: "index_taggings_on_tenant"
  end

  create_table "tags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.integer "taggings_count", default: 0
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_tags_on_name", unique: true
  end

  create_table "telegram_hook_receipts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "message_id", null: false
    t.string "outcome", null: false
    t.string "reason"
    t.integer "telegram_hook_id", null: false
    t.datetime "updated_at", null: false
    t.integer "webhook_id"
    t.index ["telegram_hook_id", "message_id"], name: "index_telegram_hook_receipts_on_hook_and_message", unique: true
    t.index ["telegram_hook_id"], name: "index_telegram_hook_receipts_on_telegram_hook_id"
    t.index ["webhook_id"], name: "index_telegram_hook_receipts_on_webhook_id"
    t.check_constraint "outcome IN ('sent', 'filtered')", name: "telegram_hook_receipts_outcome"
  end

  create_table "telegram_hooks", force: :cascade do |t|
    t.string "chat_ids", default: "", null: false
    t.string "chat_types", default: "private", null: false
    t.datetime "created_at", null: false
    t.integer "debounce_minutes", default: 5, null: false
    t.boolean "enabled", default: false, null: false
    t.boolean "ignore_channels", default: true, null: false
    t.boolean "ignore_muted", default: true, null: false
    t.integer "mcp_server_id", null: false
    t.boolean "mentions_only", default: false, null: false
    t.string "owner_status", default: "active", null: false
    t.string "respond_by_status", default: "every", null: false
    t.text "secret", null: false
    t.string "secret_header", default: "Authorization", null: false
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["mcp_server_id"], name: "index_telegram_hooks_on_mcp_server_id"
    t.check_constraint "debounce_minutes >= 0 AND debounce_minutes <= 1440", name: "telegram_hooks_debounce_minutes"
    t.check_constraint "owner_status IN ('active', 'away')", name: "telegram_hooks_owner_status"
    t.check_constraint "respond_by_status IN ('every', 'active', 'away')", name: "telegram_hooks_respond_by_status"
  end

  create_table "users", force: :cascade do |t|
    t.string "avatar_url"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "firstname"
    t.string "lastname"
    t.string "password_digest"
    t.string "provider"
    t.string "uid"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["provider", "uid"], name: "index_users_on_provider_and_uid", unique: true, where: "provider IS NOT NULL AND uid IS NOT NULL"
  end

  create_table "users_roles", id: false, force: :cascade do |t|
    t.bigint "role_id"
    t.bigint "user_id"
    t.index ["role_id"], name: "index_users_roles_on_role_id"
    t.index ["user_id", "role_id"], name: "index_users_roles_on_user_id_and_role_id"
    t.index ["user_id"], name: "index_users_roles_on_user_id"
  end

  create_table "webhooks", force: :cascade do |t|
    t.boolean "async", default: false
    t.text "body"
    t.datetime "created_at", null: false
    t.text "error_backtrace"
    t.string "error_message"
    t.json "headers"
    t.string "method"
    t.text "response_body"
    t.integer "response_code"
    t.json "response_headers"
    t.string "state", default: "created"
    t.datetime "updated_at", null: false
    t.string "url"
    t.integer "webhookable_id"
    t.string "webhookable_type"
    t.index ["created_at"], name: "index_webhooks_on_created_at"
    t.index ["webhookable_type", "webhookable_id"], name: "index_webhooks_on_webhookable"
  end

  create_table "whatsapp_hook_receipts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "message_id", null: false
    t.string "outcome", null: false
    t.string "reason"
    t.datetime "updated_at", null: false
    t.integer "webhook_id"
    t.integer "whatsapp_hook_id", null: false
    t.index ["webhook_id"], name: "index_whatsapp_hook_receipts_on_webhook_id"
    t.index ["whatsapp_hook_id", "message_id"], name: "index_whatsapp_hook_receipts_on_hook_and_message", unique: true
    t.index ["whatsapp_hook_id"], name: "index_whatsapp_hook_receipts_on_whatsapp_hook_id"
    t.check_constraint "outcome IN ('sent', 'filtered')", name: "whatsapp_hook_receipts_outcome"
  end

  create_table "whatsapp_hooks", force: :cascade do |t|
    t.string "chat_kinds", default: "direct,group", null: false
    t.boolean "consider_all_messages", default: false, null: false
    t.boolean "consider_mentions", default: true, null: false
    t.string "consider_words", default: "bot", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.integer "history_limit"
    t.integer "mcp_server_id", null: false
    t.string "owner_status", default: "active", null: false
    t.string "respond_by_status", default: "every", null: false
    t.string "respond_numbers_filtered_in", default: "", null: false
    t.string "respond_numbers_filtered_out", default: "", null: false
    t.string "respond_when", default: "mention", null: false
    t.text "secret", null: false
    t.string "secret_header", default: "Authorization", null: false
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["mcp_server_id"], name: "index_whatsapp_hooks_on_mcp_server_id"
    t.check_constraint "owner_status IN ('active', 'away')", name: "whatsapp_hooks_owner_status"
    t.check_constraint "respond_by_status IN ('every', 'active', 'away')", name: "whatsapp_hooks_respond_by_status"
    t.check_constraint "respond_when IN ('never', 'always', 'mention', 'word')", name: "whatsapp_hooks_respond_when"
  end

  add_foreign_key "context_memberships", "mcp_servers"
  add_foreign_key "context_memberships", "mcp_servers", column: "context_id"
  add_foreign_key "mcp_oauth_access_tokens", "mcp_oauth_clients"
  add_foreign_key "mcp_oauth_access_tokens", "mcp_servers"
  add_foreign_key "mcp_oauth_auth_codes", "mcp_oauth_clients"
  add_foreign_key "mcp_oauth_auth_codes", "mcp_servers"
  add_foreign_key "mcp_oauth_clients", "mcp_servers"
  add_foreign_key "mcp_oauth_login_states", "mcp_servers"
  add_foreign_key "mcp_oauth_refresh_tokens", "mcp_oauth_clients"
  add_foreign_key "mcp_oauth_refresh_tokens", "mcp_servers"
  add_foreign_key "mcp_provider_oauth_states", "mcp_servers"
  add_foreign_key "mcp_servers", "mcp_server_types"
  add_foreign_key "mcp_servers", "users"
  add_foreign_key "plans", "plan_types"
  add_foreign_key "plans", "users"
  add_foreign_key "taggings", "tags"
  add_foreign_key "telegram_hook_receipts", "telegram_hooks"
  add_foreign_key "telegram_hook_receipts", "webhooks", on_delete: :nullify
  add_foreign_key "telegram_hooks", "mcp_servers"
  add_foreign_key "whatsapp_hook_receipts", "webhooks", on_delete: :nullify
  add_foreign_key "whatsapp_hook_receipts", "whatsapp_hooks"
  add_foreign_key "whatsapp_hooks", "mcp_servers"
end
