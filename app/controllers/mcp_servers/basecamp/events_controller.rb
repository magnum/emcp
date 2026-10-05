# frozen_string_literal: true

module McpServers
  module Basecamp
    class EventsController < ApplicationController
      skip_forgery_protection

      def create
        server = McpServer.find_by(id: request.path_parameters[:id])
        head :not_found and return unless server.is_a?(Emcp::Servers::Basecamp::Server)
        head :unauthorized and return unless server.inbound_token_match?(request.path_parameters[:token])

        server.accept_basecamp_event!(request.raw_post)
        head :ok
      end
    end
  end
end
