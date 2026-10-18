# frozen_string_literal: true

class AddOrdToMcpServers < ActiveRecord::Migration[8.1]
  def change
    add_column :mcp_servers, :ord, :integer, null: false, default: 0
  end
end
