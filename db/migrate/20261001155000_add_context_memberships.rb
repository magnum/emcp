# frozen_string_literal: true

class AddContextMemberships < ActiveRecord::Migration[8.1]
  def change
    add_column :mcp_servers, :active, :boolean, default: true, null: false

    create_table :context_memberships do |t|
      t.references :context, null: false, foreign_key: { to_table: :mcp_servers }
      t.references :mcp_server, null: false, foreign_key: true
      t.boolean :active, null: false, default: true
      t.timestamps
    end

    add_index :context_memberships, [ :context_id, :mcp_server_id ], unique: true
    add_check_constraint :context_memberships, "context_id <> mcp_server_id", name: "context_memberships_no_self"
  end
end
