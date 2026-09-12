# frozen_string_literal: true

require "fileutils"
require "shellwords"

# File-backed audit trail of MCP tool calls. One Logger per server at
# {directory}/{mcp_server_code}.log, rotated daily. PurgeMcpActivityLogsJob
# deletes dated siblings older than Settings.logs.retain_days.
class McpActivityLog
  SENSITIVE_KEYS = %w[
    authorization password token access_token refresh_token client_secret
    api_token credentials credentials_json op_service_account_token
  ].freeze

  class << self
    def record(server:, tool:, status:, command: nil, ip: nil, user: nil)
      code = sanitize_code(server)
      line = [
        "ip=#{quote(ip.presence || "-")}",
        "server=#{quote(code)}",
        "user=#{quote(user.presence || "-")}",
        "tool=#{quote(tool.presence || "-")}",
        "status=#{status.to_s == "ok" ? "ok" : "ko"}",
        "command=#{quote(command.presence || "-")}",
      ].join(" ")
      logger_for(code).info(line)
    rescue StandardError => e
      Rails.logger.warn("[mcp] activity log failed: #{e.class}: #{e.message}")
    end

    def purge_expired
      cutoff = retain_days.days.ago.to_date
      Dir.glob(directory.join("*.log.*")).each do |path|
        match = File.basename(path).match(/\A.+\.log\.(\d{8})\z/)
        next unless match

        file_date = Date.strptime(match[1], "%Y%m%d")
        File.delete(path) if file_date < cutoff
      end
    end

    def path_for(server)
      directory.join("#{sanitize_code(server)}.log")
    end

    def retain_days
      days = Settings.logs.retain_days.to_i
      days.positive? ? days : 30
    end

    def directory
      relative = Settings.logs.directory.to_s
      relative = "log" if relative.empty?
      path = Rails.root.join(relative)
      return path unless Rails.env.test?

      worker = ENV["TEST_ENV_NUMBER"].to_s
      worker.empty? ? path : path.join("w#{worker}")
    end

    def reset!
      return unless defined?(@loggers) && @loggers

      @loggers.each_value { |logger| logger.close rescue nil }
      @loggers = Concurrent::Map.new
    end

    private

    def logger_for(code)
      loggers[code] ||= begin
        path = path_for(code)
        FileUtils.mkdir_p(File.dirname(path))
        logger = Logger.new(path, "daily")
        logger.progname = code
        logger.formatter = formatter
        logger
      end
    end

    def loggers
      @loggers ||= Concurrent::Map.new
    end

    def formatter
      proc do |severity, time, progname, msg|
        "#{time.iso8601(3)} #{severity} #{progname} #{msg}\n"
      end
    end

    def sanitize_code(value)
      code = value.to_s.downcase.gsub(/[^a-z0-9_-]/, "")
      code.empty? ? "unknown" : code
    end

    def quote(value)
      text = value.to_s
      return text if text.match?(/\A[\w.@:+\/-]+\z/)

      text.dump
    end
  end

  def self.redact_arguments(arguments)
    case arguments
    when Hash
      arguments.each_with_object({}) do |(key, item), out|
        out[key] =
          if SENSITIVE_KEYS.include?(key.to_s.downcase)
            "[REDACTED]"
          else
            redact_arguments(item)
          end
      end
    when Array
      arguments.map { |item| redact_arguments(item) }
    else
      arguments
    end
  end

  def self.command_from_arguments(tool, arguments)
    redacted = redact_arguments(arguments.to_h)
    parts = [tool.to_s]
    redacted.each do |key, value|
      next if value.nil? || value == ""

      parts << "#{key}=#{value.is_a?(String) ? value : value.to_json}"
    end
    parts.join(" ")
  end
end
