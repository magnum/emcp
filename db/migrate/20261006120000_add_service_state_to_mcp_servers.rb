# frozen_string_literal: true

class AddServiceStateToMcpServers < ActiveRecord::Migration[8.1]
  def change
    add_column :mcp_servers, :service_state, :string, null: false, default: "created"
    add_column :mcp_servers, :service_info, :json
    add_check_constraint :mcp_servers,
      "service_state IN ('created', 'connected', 'disconnected')",
      name: "mcp_servers_service_state"
  end
end
