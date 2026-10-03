# frozen_string_literal: true

class AddWhatsappHookRules < ActiveRecord::Migration[8.1]
  def change
    add_column :whatsapp_hooks, :respond_when, :string, null: false, default: "mention"
    add_check_constraint :whatsapp_hooks, "respond_when IN ('never', 'always', 'mention', 'word')", name: "whatsapp_hooks_respond_when"
    add_column :whatsapp_hooks, :history_limit, :integer
    change_column_default :whatsapp_hooks, :consider_words, from: "embot", to: "bot"
  end
end
