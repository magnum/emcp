# frozen_string_literal: true

# Drops daily-rotated MCP activity logs older than Settings.logs.retain_days.
class PurgeMcpActivityLogsJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: -> { "purge_mcp_activity_logs" }, duration: 10.minutes

  def perform
    McpActivityLog.purge_expired
  end
end
