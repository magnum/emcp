# frozen_string_literal: true

class NullifyWebhookOnHookReceipts < ActiveRecord::Migration[8.1]
  def change
    add_index :webhooks, :created_at

    remove_foreign_key :whatsapp_hook_receipts, :webhooks
    add_foreign_key :whatsapp_hook_receipts, :webhooks, on_delete: :nullify
  end
end
