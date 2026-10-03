# frozen_string_literal: true

class AddChatKindsToWhatsappHooks < ActiveRecord::Migration[8.1]
  def change
    add_column :whatsapp_hooks, :chat_kinds, :string, null: false, default: "direct,group"
  end
end
