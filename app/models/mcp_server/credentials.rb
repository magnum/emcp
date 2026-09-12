# frozen_string_literal: true

require "yaml"

module McpServer::Credentials
  extend ActiveSupport::Concern

  def data_dir
    ident = persisted? ? id : "new-#{object_id}"
    path = Rails.root.join("storage", "mcp", "instances", ident.to_s)
    FileUtils.mkdir_p(path)
    path.to_s
  end

  def instance_settings_path
    File.join(data_dir, "server.yml")
  end

  def credential_path
    instance_settings_path
  end

  def oauth_token_path
    File.join(data_dir, "oauth_token.json")
  end

  def load_credentials!
    migrate_legacy_credentials_env!
    stored = credential_hash
    file = read_instance_settings
    apply_credential_hash!(stored)
    apply_credential_hash!(file)
    sanitize_credential_env!
    mirror_instance_settings!(stored.merge(file))
  end

  def persist_credentials!(values)
    current = credential_hash
    values.each do |key, value|
      key = key.to_s
      next unless credential_env_keys.include?(key)

      cleaned = Emcp.sanitize_env_value(value)
      if cleaned.empty?
        current.delete(key)
        ENV.delete(key)
      else
        current[key] = cleaned
        ENV[key] = cleaned
      end
    end

    self.credentials_hash = current
    save! if persisted?
    write_instance_settings(current)
    invalidate_auth_status!
  end

  def clear_oauth_token_file!
    File.delete(oauth_token_path) if File.file?(oauth_token_path)
    self.oauth_token_hash = nil
    save! if persisted?
  end

  def persist_oauth_token_payload!(payload)
    raise "OAuth token payload must be a JSON object" unless payload.is_a?(Hash)

    self.oauth_token_hash = payload
    save! if persisted?
    FileUtils.mkdir_p(File.dirname(oauth_token_path))
    File.write(oauth_token_path, JSON.pretty_generate(payload) + "\n", perm: 0o600)
  end

  def oauth_result_body(result)
    raise "Empty OAuth token response" if result.nil?

    body = result.is_a?(Hash) ? (result[:body] || result["body"] || result) : nil
    raise "OAuth token response body is missing" unless body.is_a?(Hash)

    status = result[:status] || result["status"]
    if status && !status.to_i.between?(200, 299)
      raise "OAuth token exchange failed with status #{status}"
    end

    stringify_keys(body)
  end

  def parse_token_json_paste(token_json)
    raw = token_json.to_s.strip
    return nil if raw.empty?

    parsed = JSON.parse(raw)
    raise "token_json must be a JSON object" unless parsed.is_a?(Hash)

    parsed
  rescue JSON::ParserError => e
    raise "invalid token_json: #{e.message}"
  end

  def store_oauth_token_payload!(payload, rejection_message:)
    body = stringify_keys(payload)
    access_token = Emcp.sanitize_env_value(body["access_token"])
    raise "OAuth response did not include an access_token" if access_token.empty?
    raise "oauth_access_env is not configured" if oauth_access_env.to_s.empty?

    persist_oauth_token_payload!(body)
    updates = { oauth_access_env => access_token }
    updates[oauth_refresh_env] = Emcp.sanitize_env_value(body["refresh_token"]) if oauth_refresh_env
    persist_credentials!(updates)
    replace_client!
    raise rejection_message unless auth_status(force: true)[:authenticated]

    schedule_service_token_refresh_job!
    true
  end

  def persist_refreshed_oauth_token!(access_token:, refresh_token:, body:)
    persist_oauth_token_payload!(body) if body.is_a?(Hash)
    updates = { oauth_access_env => access_token }
    updates[oauth_refresh_env] = refresh_token if oauth_refresh_env
    persist_credentials!(updates)
  end

  def apply_credentials_probe!(updates, rejection_message:)
    old = credential_env_keys.to_h { |key| [key, ENV[key]] }
    persist_credentials!(updates)
    replace_client!
    status = auth_status(force: true)
    if status[:authenticated]
      schedule_service_token_refresh_job!
      return true
    end

    persist_credentials!(old)
    replace_client!
    detail = status[:error].to_s.strip
    raise(detail.empty? ? rejection_message : "#{rejection_message}: #{detail}")
  end

  def oauth_access_env = nil
  def oauth_refresh_env = nil

  private

  def credential_hash
    credentials_hash.transform_keys(&:to_s)
  end

  def apply_credential_hash!(values)
    values.each do |key, value|
      key = key.to_s
      next unless credential_env_keys.include?(key)

      cleaned = Emcp.sanitize_env_value(value)
      if cleaned.empty?
        ENV.delete(key)
      else
        ENV[key] = cleaned
      end
    end
  end

  def read_instance_settings
    path = instance_settings_path
    return {} unless File.file?(path)

    raw = YAML.safe_load(File.read(path), permitted_classes: [ Date, Time ], aliases: true)
    normalize_instance_settings(raw)
  rescue Psych::SyntaxError
    {}
  end

  def normalize_instance_settings(raw)
    return {} unless raw.is_a?(Hash)

    data = raw["credentials"].is_a?(Hash) ? raw["credentials"] : raw
    data.to_h.transform_keys(&:to_s).transform_values { |value| Emcp.sanitize_env_value(value) }
  end

  def mirror_instance_settings!(hash)
    return unless persisted?
    return if File.file?(instance_settings_path)

    kept = hash.select do |key, value|
      credential_env_keys.include?(key.to_s) && Emcp.sanitize_env_value(value).present?
    end
    write_instance_settings(kept) if kept.any?
  end

  def write_instance_settings(hash)
    if hash.empty?
      File.delete(instance_settings_path) if File.file?(instance_settings_path)
    else
      File.write(instance_settings_path, YAML.dump(hash.transform_keys(&:to_s)), perm: 0o600)
    end
    File.delete(legacy_credential_path) if File.file?(legacy_credential_path)
  end

  def legacy_credential_path
    File.join(data_dir, "credentials.env")
  end

  def migrate_legacy_credentials_env!
    return unless File.file?(legacy_credential_path)
    return if File.file?(instance_settings_path)

    parsed = {}
    File.readlines(legacy_credential_path, chomp: true).each do |line|
      next if line.empty? || line.start_with?("#")

      key, value = line.split("=", 2)
      next unless key && value && credential_env_keys.include?(key)

      parsed[key] = Emcp.sanitize_env_value(value)
    end
    write_instance_settings(parsed) if parsed.any?
    File.delete(legacy_credential_path) if File.file?(legacy_credential_path)
  end

  def sanitize_credential_env!
    credential_env_keys.each do |key|
      next unless ENV.key?(key)

      cleaned = Emcp.sanitize_env_value(ENV[key])
      if cleaned.empty?
        ENV.delete(key)
      else
        ENV[key] = cleaned
      end
    end
  end
end
