# frozen_string_literal: true

class HealthController < ApplicationController
  def show
    McpServerType.discover! if ActiveRecord::Base.connection.data_source_exists?("mcp_server_types")
    servers = McpServerType.order(:code).map do |server_type|
      {
        id: server_type.code,
        name: server_type.name,
      }
    end
    render json: {
      status: "ok",
      version: Emcp::VERSION,
      servers: servers,
    }
  rescue StandardError => e
    render json: { status: "error", error: e.message }, status: :service_unavailable
  end
end
