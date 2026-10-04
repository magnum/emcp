# frozen_string_literal: true

class BrowserChannel < ApplicationCable::Channel
  def subscribed
    ::McpServer.ensure_integrations_loaded!
    server = ::McpServer.find_by(id: browser_server_id)
    reject unless server.is_a?(::Emcp::Servers::Browser::Server)

    registry.supersede(server.id)
    stale_after = ::Emcp::Servers::Browser::SessionRegistry.heartbeat_seconds_for(server) * 3
    @generation = registry.attach(server.id, connection, stale_after: stale_after)
    server.mark_paired!
    stream_from registry.stream_name(server.id)
  end

  def unsubscribed
    return unless @generation

    registry.detach(browser_server_id, @generation)
  end

  def receive(data)
    body = data.to_h.transform_keys(&:to_s)
    if body["kind"] == "heartbeat"
      registry.touch(browser_server_id)
    elsif body["request_id"].present?
      registry.complete(body["request_id"], body)
    end
  end

  private

  def registry
    ::Emcp::Servers::Browser::SessionRegistry.current
  end
end
