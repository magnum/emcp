# frozen_string_literal: true

# Recurring safety net for provider tokens. ServerAuthTokenRefreshJob only
# reschedules itself after a successful credential save; a deploy, a
# DeserializationError, or a job that never started leaves Google/Twitter/…
# without any refresh until the operator re-auths.
class EnsureServiceTokenRefreshJob < ApplicationJob
  queue_as :default

  def perform
    McpServer.discover!
    McpServer.find_each do |server|
      next unless server.service_token_refresh_enabled?

      server.load_credentials!
      ok = server.refresh_service_token!
      Rails.logger.info("[#{server.code}] service token refresh #{ok ? "updated" : "skipped_or_failed"}")
    end
  end
end
