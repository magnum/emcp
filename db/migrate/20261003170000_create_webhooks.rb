# frozen_string_literal: true

class CreateWebhooks < ActiveRecord::Migration[8.1]
  def change
    create_table :webhooks do |t|
      t.string :state, default: "created"
      t.references :webhookable, polymorphic: true, index: true
      t.boolean :async, default: false
      t.string :url
      t.string :method
      t.json :headers
      t.text :body
      t.integer :response_code
      t.text :response_body
      t.json :response_headers
      t.string :error_message
      t.text :error_backtrace
      t.timestamps
    end

    create_table :whatsapp_hooks do |t|
      t.references :mcp_server, null: false, foreign_key: true
      t.string :url, null: false
      t.text :secret, null: false
      t.string :secret_header, null: false, default: "Authorization"
      t.boolean :enabled, null: false, default: true
      t.string :owner_status, null: false, default: "active"
      t.boolean :consider_mentions, null: false, default: true
      t.boolean :consider_all_messages, null: false, default: false
      t.string :consider_words, null: false, default: "embot"
      t.string :respond_by_status, null: false, default: "every"
      t.string :respond_numbers_filtered_in, null: false, default: ""
      t.string :respond_numbers_filtered_out, null: false, default: ""
      t.timestamps
    end

    add_check_constraint :whatsapp_hooks, "owner_status IN ('active', 'away')", name: "whatsapp_hooks_owner_status"
    add_check_constraint :whatsapp_hooks, "respond_by_status IN ('every', 'active', 'away')", name: "whatsapp_hooks_respond_by_status"

    create_table :whatsapp_hook_receipts do |t|
      t.references :whatsapp_hook, null: false, foreign_key: true
      t.string :message_id, null: false
      t.string :outcome, null: false
      t.string :reason
      t.references :webhook, foreign_key: true
      t.timestamps
    end

    add_index :whatsapp_hook_receipts, [ :whatsapp_hook_id, :message_id ], unique: true,
              name: "index_whatsapp_hook_receipts_on_hook_and_message"
    add_check_constraint :whatsapp_hook_receipts, "outcome IN ('sent', 'filtered')", name: "whatsapp_hook_receipts_outcome"
  end
end
