# frozen_string_literal: true

require "fileutils"
require "json"
require "mcp"

class McpServer < ApplicationRecord
  include McpServer::Tools
  include McpServer::Credentials
  include McpServer::AuthStatus
  include McpServer::ServiceTokenRefresh

  acts_as_taggable_on :tags
  acts_as_taggable_tenant :user_id

  belongs_to :user
  belongs_to :mcp_server_type

  has_many :mcp_oauth_clients, dependent: :destroy
  has_many :mcp_oauth_access_tokens, dependent: :destroy
  has_many :mcp_oauth_refresh_tokens, dependent: :destroy
  has_many :mcp_oauth_auth_codes, dependent: :destroy
  has_many :mcp_oauth_login_states, dependent: :destroy
  has_many :mcp_provider_oauth_states, dependent: :destroy

  encrypts :credentials, :oauth_token_payload

  validates :name, presence: true
  validates :type, presence: true
  validates :token_refresh_in_minutes,
            numericality: { only_integer: true, greater_than: 0 },
            allow_nil: true
  validates :service_token_refresh_in_minutes,
            numericality: { only_integer: true, greater_than: 0 },
            allow_nil: true

  before_validation :apply_type_defaults, on: :create
  before_validation :normalize_token_refresh_in_minutes
  before_validation :normalize_service_token_refresh_in_minutes

  after_initialize :prepare_runtime
  after_find :prepare_runtime

  delegate :code, :version, :oauth_token_retrieval, :oauth_token_retrieval?,
           :class_name, to: :mcp_server_type, allow_nil: true

  scope :for_user, ->(user) { where(user: user) }
  scope :search, ->(query) {
    return all if query.blank?

    pattern = "%#{sanitize_sql_like(query.to_s.strip)}%"
    left_joins(:mcp_server_type).where(
      "mcp_servers.name LIKE :q OR mcp_servers.description LIKE :q OR mcp_server_types.name LIKE :q",
      q: pattern,
    )
  }

  def credentials_hash
    parse_json_attr(credentials)
  end

  def credentials_hash=(value)
    self.credentials = JSON.generate(value || {})
  end

  def oauth_token_hash
    parse_json_attr(oauth_token_payload)
  end

  def oauth_token_hash=(value)
    self.oauth_token_payload = value.nil? ? nil : JSON.generate(value)
  end

  def self.model_name
    ActiveModel::Name.new(self, nil, "McpServer")
  end

  class << self
    attr_reader :server_id_value, :display_name_value, :description_value, :version_value

    def server_id(value = nil)
      @server_id_value = value if value
      @server_id_value
    end

    def display_name(value = nil)
      @display_name_value = value if value
      @display_name_value || server_id
    end

    def description(value = nil)
      @description_value = value if value
      @description_value || ""
    end

    def version(value = nil)
      @version_value = value if value
      @version_value || "1.0.0"
    end

    def oauth_token_retrieval(value = nil)
      @oauth_token_retrieval_value = !!value unless value.nil?
      @oauth_token_retrieval_value || false
    end

    def integration_classes
      @integration_classes ||= []
    end

    def register_integration(klass)
      integration_classes << klass unless integration_classes.include?(klass)
    end

    def discover!
      McpServerType.discover!
    end

    def rewrite_legacy_sti_types!
      if connection.data_source_exists?("mcp_servers") && connection.column_exists?(:mcp_servers, :type)
        connection.execute(<<~SQL.squish)
          UPDATE mcp_servers
          SET type = REPLACE(type, 'Madcp::', 'Emcp::')
          WHERE type LIKE 'Madcp::%'
        SQL
      end

      return unless connection.data_source_exists?("mcp_server_types")

      connection.execute(<<~SQL.squish)
        UPDATE mcp_server_types
        SET class_name = REPLACE(class_name, 'Madcp::', 'Emcp::')
        WHERE class_name LIKE 'Madcp::%'
      SQL
    end

    def ensure_integrations_loaded!
      if Rails.application.config.cache_classes
        load_integration_code! if integration_classes.empty?
      else
        reload_integration_code!
      end
    end

    def load_integration_code!
      Rails.root.glob("servers/*/server.rb").sort.each { |path| require path.to_s }
    end

    def reload_integration_code!
      @integration_classes = []
      unload_servers_namespace!
      clear_servers_loaded_features!
      load_integration_code!
    end

    def unload_servers_namespace!
      return unless Emcp.const_defined?(:Servers, false)

      Emcp.send(:remove_const, :Servers)
    end

    def clear_servers_loaded_features!
      root = Rails.root.join("servers").to_s
      $LOADED_FEATURES.reject! { |feature| feature.start_with?(root) }
    end
    private :unload_servers_namespace!, :clear_servers_loaded_features!

    def fetch!(type_code, id = nil)
      if id.nil?
        raise ArgumentError, "McpServer.fetch! requires type_code and id"
      end

      includes(:mcp_server_type).find_by!(id: id).tap do |server|
        unless server.code.to_s == type_code.to_s
          raise ActiveRecord::RecordNotFound, "Couldn't find McpServer with type #{type_code.inspect} and id #{id.inspect}"
        end
      end
    end

    def for_user_and_code!(user, code)
      user.mcp_servers.joins(:mcp_server_type).find_by!(mcp_server_types: { code: code.to_s })
    end

    def provision_defaults_for!(user)
      return if user.blank?

      discover!
      McpServerType.find_each do |server_type|
        next if exists?(user: user, mcp_server_type: server_type)

        create!(
          user: user,
          mcp_server_type: server_type,
          name: server_type.name,
          description: "",
        )
      end
    end

    def purge_legacy_storage!(root: Rails.root.join("storage", "mcp"))
      return [] unless File.directory?(root)

      Dir.children(root).filter_map do |entry|
        next if entry == "instances"

        FileUtils.rm_rf(File.join(root, entry))
        entry
      end
    end
  end

  # Legacy Integration used #id for server_id; AR #id remains the PK.
  def server_id = code
  def display_name = name
  def allow_write_methods? = allow_write?
  def token_refresh_enabled? = token_refresh_in_minutes.to_i.positive?
  def activity_log_code = persisted? ? "#{code}-#{id}" : code.to_s

  # Optional display / auth-form hooks. Override in servers/*/server.rb.
  def instructions = "#{display_name} MCP integration."
  def auth_fields = []
  def auth_help_content = nil

  def oauth_app_auth_fields
    auth_fields.select { |field| field[:oauth_app] }
  end

  def credential_auth_fields
    auth_fields.reject { |field| field[:oauth_app] }
  end

  # Persist provider app credentials from the auth form before starting OAuth.
  # Non-empty form values win over ENV / stored credentials; blank password fields keep existing.
  def prepare_provider_oauth!(_params) = nil

  # Required integration contract. Concrete servers in servers/*/server.rb must implement these.
  # Optional: refresh_service_token! defaults to false (see McpServer::ServiceTokenRefresh).
  def configure_tools = raise(NotImplementedError)
  def apply_credentials(_params) = raise(NotImplementedError)
  def clear_credentials! = raise(NotImplementedError)
  def fetch_auth_status = raise(NotImplementedError)
  def replace_client! = raise(NotImplementedError)
  def credential_env_keys = raise(NotImplementedError)

  # Required only for OAuth-provider servers (Twitter, Fatture in Cloud, …).
  def oauth_call(callback_url:, state:) = raise(NotImplementedError)
  def oauth_exchange(callback_url:, params:, state_data: nil) = raise(NotImplementedError)

  def apply_oauth_result!(result)
    store_oauth_token_payload!(
      oauth_result_body(result),
      rejection_message: "#{display_name} token was rejected",
    )
  end

  def apply_oauth_token_paste!(access_token:, token_json: nil)
    token = Emcp.sanitize_env_value(access_token)
    raise "Access token is required" if token.empty?

    payload = parse_token_json_paste(token_json) || {}
    payload = payload.merge("access_token" => token)
    store_oauth_token_payload!(
      payload,
      rejection_message: "#{display_name} token was rejected",
    )
  end

  def issuer_url
    "#{Emcp.public_url}/servers/#{code}/#{id}"
  end

  def mcp_url
    "#{issuer_url}/mcp"
  end

  def provider_oauth_callback_url
    "#{issuer_url}/oauth_callback"
  end

  def available_tag_names
    return [] if user_id.blank?

    ActsAsTaggableOn::Tag.for_tenant(user_id).for_context(:tags).order(:name).pluck(:name)
  end

  private

  def apply_type_defaults
    return unless mcp_server_type

    self.type = mcp_server_type.class_name if type.blank? || instance_of?(McpServer)
    self.name = mcp_server_type.name if name.blank?
    self.allow_write = mcp_server_type.allow_write unless allow_write_changed?
    self.service_token_refresh_in_minutes ||= mcp_server_type.service_token_refresh_in_minutes
    self.token_refresh_in_minutes ||= mcp_server_type.token_refresh_in_minutes
  end

  def parse_json_attr(raw)
    return {} if raw.blank?
    return raw if raw.is_a?(Hash)

    JSON.parse(raw)
  rescue JSON::ParserError
    {}
  end

  def normalize_token_refresh_in_minutes
    self.token_refresh_in_minutes = nil unless token_refresh_in_minutes.to_i.positive?
  end

  def normalize_service_token_refresh_in_minutes
    self.service_token_refresh_in_minutes = nil unless service_token_refresh_in_minutes.to_i.positive?
  end

  def prepare_runtime
    return if @runtime_prepared

    @runtime_prepared = true
    @configured = false
    @tools = []
    @resources = []
    return if instance_of?(McpServer)

    if code.present?
      Emcp.apply_server_type_settings!(code)
      load_credentials!
    end
    ensure_runtime_client
  end

  def ensure_runtime_client
    return if defined?(@client) && @client

    replace_client!
  end
end
