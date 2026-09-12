# frozen_string_literal: true

class McpServerType < ApplicationRecord
  has_many :mcp_servers, dependent: :restrict_with_error

  validates :code, presence: true, uniqueness: true
  validates :class_name, presence: true, uniqueness: true
  validates :name, presence: true

  class << self
    def discover!
      McpServer.rewrite_legacy_sti_types!
      McpServer.ensure_integrations_loaded!
      sync_from_registry!
    end

    def sync_from_registry!
      now = Time.current
      McpServer.integration_classes.each do |klass|
        code = klass.server_id
        next if code.blank?

        allow_write = ActiveModel::Type::Boolean.new.cast(
          ENV.fetch("#{code.upcase}_ALLOW_WRITE", "false"),
        )
        attrs = {
          class_name: klass.name,
          name: klass.display_name,
          description: klass.description,
          version: klass.version,
          oauth_token_retrieval: klass.oauth_token_retrieval,
          allow_write: allow_write,
          service_token_refresh_in_minutes: klass.default_service_token_refresh_in_minutes,
          updated_at: now,
        }
        existing = find_by(code: code)
        if existing
          existing.update_columns(attrs)
        else
          insert({
            code: code,
            created_at: now,
            **attrs,
          })
        end
      end
    end

    def fetch!(code)
      find_by!(code: code.to_s)
    end
  end

  def integration_class
    class_name.constantize
  end
end
