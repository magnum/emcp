# frozen_string_literal: true

# Safety net for the bundled WhatsApp sidecar. The process must live in the web
# container (127.0.0.1), so this no-ops on the Solid Queue worker. Puma starts
# the same keepalive loop on boot — this job covers processes that already have
# Solid Queue in Puma, and development `bin/dev`.
class WhatsappBridgeKeepaliveJob < ApplicationJob
  queue_as :default

  def perform
    unless Emcp::Servers::Whatsapp::Keepalive.can_spawn_locally?
      Rails.logger.debug("[whatsapp keepalive] skip: not the web process")
      return
    end

    Emcp::Servers::Whatsapp::Keepalive.ping_all
  end
end
