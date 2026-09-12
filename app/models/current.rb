class Current < ActiveSupport::CurrentAttributes
  attribute :user
  attribute :remote_ip
  attribute :mcp_actor
  attribute :mcp_command
end
