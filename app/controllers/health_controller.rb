# frozen_string_literal: true

class HealthController < ActionController::Base
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

  def ready
    ActiveRecord::Base.connection.select_value("SELECT 1")
    keepalive = defined?(Emcp::Servers::Whatsapp::Keepalive) && Emcp::Servers::Whatsapp::Keepalive.alive?
    payload = { status: "ok", whatsapp_keepalive: keepalive }

    if keepalive_required? && !keepalive
      render json: payload.merge(status: "degraded"), status: :service_unavailable
    else
      render json: payload
    end
  rescue StandardError
    head :service_unavailable
  end

  private

  def keepalive_required?
    return false if Rails.env.test?
    return false unless defined?(Emcp::Servers::Whatsapp::Keepalive)

    Emcp::Servers::Whatsapp::Keepalive.can_spawn_locally?
  end
end
