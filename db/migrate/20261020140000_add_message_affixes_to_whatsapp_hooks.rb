# frozen_string_literal: true

class AddMessageAffixesToWhatsappHooks < ActiveRecord::Migration[8.1]
  def change
    add_column :whatsapp_hooks, :message_prefix, :string, null: false, default: "Ⓜ️"
    add_column :whatsapp_hooks, :message_suffix, :string, null: false, default: " - bot"
  end
end