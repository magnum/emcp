# frozen_string_literal: true

module McpServers
  module Browser
    class ExtensionsController < ApplicationController
      before_action :require_authentication

      def show
        server = current_user.mcp_servers.find(params[:id])
        raise ActiveRecord::RecordNotFound unless server.is_a?(::Emcp::Servers::Browser::Server)

        send_data ::Emcp::Servers::Browser::ExtensionZip.build,
          filename: "emcp-browser-extension.zip",
          type: "application/zip",
          disposition: "attachment"
      end
    end
  end
end
