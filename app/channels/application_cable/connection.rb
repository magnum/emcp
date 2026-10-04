# frozen_string_literal: true

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :browser_server_id

    def connect
      ::McpServer.ensure_integrations_loaded!
      server = ::McpServer.find_by(id: request.params[:instance_id])
      token = request.params[:token]
      unless server.is_a?(::Emcp::Servers::Browser::Server) &&
          ::Emcp::Servers::Browser::Pairing.token_matches?(server, token)
        reject_unauthorized_connection
      end

      self.browser_server_id = server.id
    end
  end
end
