# frozen_string_literal: true

require "digest"
require "openssl"
require "json"

# Reopen the Rails application module (Emcp) with host helpers.
# Do not define lib/emcp.rb — Zeitwerk will not load it once Emcp exists.
module Emcp
  VERSION = "0.1.0" unless const_defined?(:VERSION)

  ToolDefinition = Data.define(:name, :description, :input_schema, :output_schema, :write, :handler) unless const_defined?(:ToolDefinition)
  ResourceDefinition = Data.define(:uri, :name, :description, :mime_type, :handler) unless const_defined?(:ResourceDefinition)

  module_function

  def sanitize_env_value(value)
    cleaned = value.to_s
    hash_at = cleaned.index("#")
    cleaned = cleaned[0...hash_at] if hash_at
    cleaned.strip
  end

  def secure_equals(a, b)
    OpenSSL.fixed_length_secure_compare(
      Digest::SHA256.digest(a.to_s),
      Digest::SHA256.digest(b.to_s),
    )
  end

  def public_url
    ENV.fetch("EMCP_PUBLIC_URL") { ENV.fetch("APP_HOST", "http://localhost:3000") }.to_s.sub(%r{/\z}, "")
  end

  def release_info
    return read_version_file if Rails.env.development?

    @release_info ||= read_version_file
  end

  def release_commit
    release_info[:commit]
  end

  def release_tag
    release_info[:tag]
  end

  def read_version_file(path = Rails.root.join("VERSION"))
    info = { commit: nil, tag: nil }
    return info unless File.file?(path)

    File.foreach(path) do |line|
      key, value = line.strip.split("=", 2)
      next if key.blank? || value.blank?
      next unless info.key?(key.to_sym)

      info[key.to_sym] = value
    end
    info
  end

  def apply_env_sanitization!
    ENV.each_key do |key|
      original = ENV[key]
      next if original.nil?

      cleaned = sanitize_env_value(original)
      next if cleaned == original

      if cleaned.empty?
        ENV.delete(key)
      else
        ENV[key] = cleaned
      end
    end
  end

  def register_integration(klass)
    McpServer.register_integration(klass)
  end

  def server_config(code)
    servers = Settings.try(:servers)
    return {} unless servers

    defaults = settings_hash(try_setting(servers, "defaults"))
    specific = settings_hash(try_setting(servers, code))
    defaults.merge(specific)
  end

  def server_setting(code, key, default = nil)
    value = server_config(code)[key.to_s]
    value.nil? ? default : value
  end

  def apply_server_type_settings!(code)
    config = server_config(code)
    return if config.empty?

    prefix = code.to_s.upcase
    assign_env(config["timeout"], "#{prefix}_TIMEOUT", timeout_env_for(code))
    assign_env(config["max_chars"], "#{prefix}_MAX_CHARS", "EMCP_MAX_CHARS")
    assign_env(config["allow_write"], "#{prefix}_ALLOW_WRITE")
    assign_env(config["bin"], bin_env_for(code))
    assign_env(config["oauth_scopes"], "#{prefix}_OAUTH_SCOPES")
    assign_env(config["statement_timeout_ms"], "TESLAMATE_STATEMENT_TIMEOUT_MS")
    assign_env(config["query_timeout_ms"], "TESLAMATE_QUERY_TIMEOUT_MS")
    assign_env(config["custom_sql_row_limit"], "TESLAMATE_CUSTOM_SQL_ROW_LIMIT")
    assign_env(config["insecure"], "HASS_INSECURE")
  end

  def settings_hash(node)
    return {} if node.blank?
    return node.deep_stringify_keys if node.is_a?(Hash)
    return node.to_h.deep_stringify_keys if node.respond_to?(:to_h)

    {}
  end

  def try_setting(node, key)
    return if node.nil?

    if node.respond_to?(:key?)
      return node[key] if node.key?(key)
      return node[key.to_s] if node.key?(key.to_s)
      return node[key.to_sym] if node.key?(key.to_sym)
    end

    node.public_send(key) if node.respond_to?(key)
  rescue NoMethodError
    nil
  end

  def assign_env(value, *keys)
    return if value.nil?

    string = value.to_s
    return if string.empty?

    keys.flatten.compact.uniq.each do |key|
      ENV[key.to_s] = string
    end
  end

  def timeout_env_for(code)
    {
      "homeassistant" => "HASS_TIMEOUT",
      "onepassword" => "OP_TIMEOUT",
      "googleworkspace" => "GOOGLEWORKSPACE_TIMEOUT",
    }[code.to_s]
  end

  def bin_env_for(code)
    {
      "hey" => "HEY_BIN",
      "basecamp" => "BASECAMP_BIN",
      "googleworkspace" => "GOOGLEWORKSPACE_BIN",
      "homeassistant" => "HASS_CLI_BIN",
      "onepassword" => "OP_BIN",
    }[code.to_s]
  end
end

Emcp.apply_env_sanitization!

# to_prepare re-runs after each code reload in development so STI subclasses
# under servers/ are rebound to the current McpServer class.
Rails.application.config.to_prepare do
  next if ENV["EMCP_SKIP_DISCOVER"] == "1"
  next unless ActiveRecord::Base.connection.data_source_exists?("mcp_server_types")

  McpServerType.discover!
rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid
  # db:create / first boot / sqlite not ready yet
end

Rails.application.config.after_initialize do
  next if ENV["EMCP_SKIP_DISCOVER"] == "1"
  next if Rails.env.test?
  next unless ActiveRecord::Base.connection.data_source_exists?("mcp_servers")

  McpServer.purge_legacy_storage!
rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid
  # db:create / first boot / sqlite not ready yet
end
