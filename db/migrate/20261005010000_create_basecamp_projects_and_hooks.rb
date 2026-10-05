# frozen_string_literal: true

class CreateBasecampProjectsAndHooks < ActiveRecord::Migration[8.1]
  def change
    create_table :basecamp_projects do |t|
      t.references :mcp_server, null: false, foreign_key: true
      t.string :project_id, null: false
      t.string :name, null: false
      t.string :basecamp_webhook_id, null: false
      t.timestamps
    end
    add_index :basecamp_projects, [ :mcp_server_id, :project_id ], unique: true,
              name: "index_basecamp_projects_on_server_and_project"

    create_table :basecamp_hooks do |t|
      t.references :mcp_server, null: false, foreign_key: true
      t.string :url, null: false
      t.text :secret, null: false
      t.string :secret_header, null: false, default: "Authorization"
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    create_table :basecamp_hook_receipts do |t|
      t.references :basecamp_hook, null: false, foreign_key: true
      t.string :event_id, null: false
      t.string :outcome, null: false
      t.string :reason
      t.references :webhook, foreign_key: { on_delete: :nullify }
      t.timestamps
    end
    add_index :basecamp_hook_receipts, [ :basecamp_hook_id, :event_id ], unique: true,
              name: "index_basecamp_hook_receipts_on_hook_and_event"
    add_check_constraint :basecamp_hook_receipts, "outcome IN ('sent', 'filtered')", name: "basecamp_hook_receipts_outcome"
  end
end
