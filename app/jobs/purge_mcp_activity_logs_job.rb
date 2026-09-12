# frozen_string_literal: true

# Drops daily-rotated MCP activity logs older than Settings.logs.retain_days.
class PurgeMcpActivityLogsJob < ApplicationJob
  queue_as :default

  def perform
    McpActivityLog.purge_expired
  end
end
