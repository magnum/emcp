# frozen_string_literal: true

class AllowMultipleWhatsappHookRespondWhen < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :whatsapp_hooks, name: "whatsapp_hooks_respond_when"
    execute "UPDATE whatsapp_hooks SET respond_when = '' WHERE respond_when = 'never'"
  end

  def down
    execute "UPDATE whatsapp_hooks SET respond_when = 'never' WHERE respond_when = '' OR respond_when IS NULL"
    execute <<~SQL.squish
      UPDATE whatsapp_hooks
      SET respond_when = 'mention'
      WHERE respond_when NOT IN ('never', 'always', 'mention', 'word')
    SQL
    add_check_constraint :whatsapp_hooks,
      "respond_when IN ('never', 'always', 'mention', 'word')",
      name: "whatsapp_hooks_respond_when"
  end
end
