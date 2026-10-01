# frozen_string_literal: true

class ContextMembership < ApplicationRecord
  belongs_to :context, class_name: "McpServer", inverse_of: :context_memberships
  belongs_to :mcp_server, inverse_of: :member_context_memberships

  scope :active, -> { where(active: true) }

  validates :mcp_server_id, uniqueness: { scope: :context_id }
  validate :same_owner
  validate :not_self
  validate :proxied_is_not_a_context

  def proxied_snapshot
    server = mcp_server
    status = server.auth_status
    {
      id: server.id,
      code: server.code,
      instance: server.activity_log_code,
      name: server.name,
      description: server.description,
      tags: server.tag_list,
      active: active?,
      authenticated: status[:authenticated] == true,
      auth: status[:authenticated] == true ? "auth" : "noauth",
      allow_write: server.allow_write?,
      mcp_url: server.mcp_url,
      error: status[:error],
    }
  end

  private

  def same_owner
    return if context.blank? || mcp_server.blank?
    return if context.user_id == mcp_server.user_id

    errors.add(:mcp_server, "must belong to the same user as the context")
  end

  def not_self
    return if context_id.blank? || mcp_server_id.blank?
    return if context_id != mcp_server_id

    errors.add(:mcp_server, "cannot proxy itself")
  end

  def proxied_is_not_a_context
    return if mcp_server.blank?
    return unless mcp_server.context?

    errors.add(:mcp_server, "cannot nested-proxy another context")
  end
end
