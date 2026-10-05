# frozen_string_literal: true

module Emcp
  module Servers
    module Basecamp
      class Project < ApplicationRecord
        self.table_name = "basecamp_projects"

        belongs_to :mcp_server

        normalizes :project_id, :name, :basecamp_webhook_id, with: ->(value) { value.to_s.strip }

        validates :project_id, :name, :basecamp_webhook_id, presence: true
        validates :project_id, uniqueness: { scope: :mcp_server_id }

        def unlink!
          remove_remote_webhook!
          destroy!
        end

        private

        def remove_remote_webhook!
          server = mcp_server
          return unless server.is_a?(Server)

          server.run_cli!([ "webhooks", "delete", basecamp_webhook_id, "--in", project_id, "--json" ])
        rescue Emcp::CliError => e
          return if e.message.match?(/not found|404|Couldn't find/i)

          raise
        end
      end
    end
  end
end
