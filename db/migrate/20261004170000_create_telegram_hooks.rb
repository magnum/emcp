# frozen_string_literal: true

class CreateTelegramHooks < ActiveRecord::Migration[8.1]
  def change
    create_table :telegram_hooks do |t|
      t.references :mcp_server, null: false, foreign_key: true
      t.string :url, null: false
      t.text :secret, null: false
      t.string :secret_header, null: false, default: "Authorization"
      t.boolean :enabled, null: false, default: false
      t.string :owner_status, null: false, default: "active"
      t.string :respond_by_status, null: false, default: "every"
      t.string :chat_ids, null: false, default: ""
      t.string :chat_types, null: false, default: "private"
      t.boolean :mentions_only, null: false, default: false
      t.boolean :ignore_muted, null: false, default: true
      t.boolean :ignore_channels, null: false, default: true
      t.integer :debounce_minutes, null: false, default: 5
      t.timestamps
    end

    add_check_constraint :telegram_hooks, "owner_status IN ('active', 'away')", name: "telegram_hooks_owner_status"
    add_check_constraint :telegram_hooks, "respond_by_status IN ('every', 'active', 'away')", name: "telegram_hooks_respond_by_status"
    add_check_constraint :telegram_hooks, "debounce_minutes >= 0 AND debounce_minutes <= 1440", name: "telegram_hooks_debounce_minutes"

    create_table :telegram_hook_receipts do |t|
      t.references :telegram_hook, null: false, foreign_key: true
      t.string :message_id, null: false
      t.string :outcome, null: false
      t.string :reason
      t.references :webhook, foreign_key: { on_delete: :nullify }
      t.timestamps
    end

    add_index :telegram_hook_receipts, [ :telegram_hook_id, :message_id ], unique: true,
              name: "index_telegram_hook_receipts_on_hook_and_message"
    add_check_constraint :telegram_hook_receipts, "outcome IN ('sent', 'filtered')", name: "telegram_hook_receipts_outcome"
  end
end
