# frozen_string_literal: true

require "fileutils"
require "json"
require "mcp"
require "uri"

class McpServer < ApplicationRecord
  include McpServer::Tools
  include McpServer::Credentials
  include McpServer::AuthStatus
  include McpServer::ServiceTokenRefresh
  include AASM

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
  has_many :context_memberships, foreign_key: :context_id, dependent: :destroy, inverse_of: :context
  has_many :proxied_servers, through: :context_memberships, source: :mcp_server
  has_many :member_context_memberships, class_name: "ContextMembership",
           foreign_key: :mcp_server_id, dependent: :destroy, inverse_of: :mcp_server

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
  after_create_commit :ensure_status_check, if: :context?
  after_destroy_commit :clear_status_signature, if: :context?

  aasm column: :service_state do
    state :created, initial: true
    state :connected
    state :disconnected

    event :connect do
      transitions from: %i[created connected disconnected], to: :connected
    end

    event :disconnect do
      transitions from: %i[created connected disconnected], to: :disconnected
    end
  end

  delegate :code, :version, :oauth_token_retrieval, :oauth_token_retrieval?,
           :class_name, to: :mcp_server_type, allow_nil: true

  scope :for_user, ->(user) { where(user: user) }
  scope :contexts, -> {
    where(mcp_server_type_id: McpServerType.select(:id).where(code: "context"))
  }
  scope :proxyable, -> {
    where.not(mcp_server_type_id: McpServerType.select(:id).where(code: "context"))
  }
  scope :search, ->(query) {
    parsed = parse_search_query(query)
    rel = all
    if parsed[:text].present?
      pattern = "%#{sanitize_sql_like(parsed[:text])}%"
      rel = rel.left_joins(:mcp_server_type).where(
        "mcp_servers.name LIKE :q OR mcp_servers.description LIKE :q OR mcp_server_types.name LIKE :q",
        q: pattern,
      )
    end
    rel = rel.tagged_with(parsed[:tags]) if parsed[:tags].any?
    rel
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

    def parse_search_query(query)
      tags = []
      text = query.to_s.gsub(/\btag:(\S*)/i) do
        tags.concat(Regexp.last_match(1).split(",").map(&:strip).reject(&:blank?))
        " "
      end
      { text: text.gsub(/\s+/, " ").strip, tags: tags.uniq }
    end

    def tag_names_for(user)
      return [] if user.blank?

      ActsAsTaggableOn::Tag.for_tenant(user.id).for_context(:tags).pluck(:name).uniq.sort
    end

    def for_user_and_code!(user, code)
      user.mcp_servers.joins(:mcp_server_type).find_by!(mcp_server_types: { code: code.to_s })
    end

    def provision_defaults_for!(user)
      return if user.blank?

      discover!
      McpServerType.find_each do |server_type|
        next if server_type.code == "context"
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
  def emcp_service_info = raise(NotImplementedError)
  def fetch_auth_status = raise(NotImplementedError)
  def replace_client! = raise(NotImplementedError)
  def credential_env_keys = raise(NotImplementedError)

  # Required only for OAuth-provider servers (Twitter, Fatture in Cloud, …).
  def service_info_report
    raw = emcp_service_info
    raw = {} unless raw.is_a?(Hash)
    detail = raw.symbolize_keys
    connected = detail.key?(:connected) ? detail[:connected] == true : detail[:authenticated] == true
    {
      "connected" => connected,
      "server" => {
        "id" => id,
        "code" => code,
        "instance" => activity_log_code,
        "name" => name,
        "type" => mcp_server_type&.name,
      },
      "emcp" => {
        "public_url" => Emcp.public_url,
        "version" => Emcp.release_tag.presence || Emcp::VERSION,
        "commit" => Emcp.release_commit,
      },
      "detail" => detail.except(:connected).as_json,
    }
  end

  def record_service_probe!
    report = service_info_report
    apply_service_report!(report)
    report["connected"] == true ? nil : service_probe_failure(report)
  rescue StandardError => e
    report = { "connected" => false, "detail" => { "error" => e.message } }
    apply_service_report!(report)
    service_probe_failure(report)
  end

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

  def context? = code.to_s == "context"

  def issuer_url
    "#{Emcp.public_url}/servers/#{code}/#{id}"
  end

  def mcp_url
    "#{issuer_url}/mcp"
  end

  def oauth_protected_resource_metadata_url
    path = URI.parse(mcp_url).path
    "#{Emcp.public_url}/.well-known/oauth-protected-resource#{path}"
  end

  def provider_oauth_callback_url
    "#{issuer_url}/oauth_callback"
  end

  def available_tag_names
    self.class.tag_names_for(user)
  end

  private

  def apply_service_report!(report)
    self.service_info = report
    if report["connected"] == true
      connect if may_connect?
    else
      disconnect if may_disconnect?
    end
    save!
  end

  def service_probe_failure(report)
    {
      id: id,
      name: name,
      instance: activity_log_code,
      error: report.dig("detail", "error") || report["error"],
    }
  end

  def ensure_status_check
    CheckStatusJob.ensure_running!(self)
  end

  def clear_status_signature
    CheckStatusJob.clear_signature!(id)
  end

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
