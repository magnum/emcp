# frozen_string_literal: true

# CORS for ChatGPT web MCP/OAuth. Native clients (Claude, ChatGPT Mac) ignore these headers;
# the browser connector on chatgpt.com requires a successful OPTIONS preflight before tools/list.
module McpCors
  extend ActiveSupport::Concern

  MCP_CORS_METHODS = "GET, POST, DELETE, OPTIONS"
  MCP_CORS_HEADERS = "Authorization, Content-Type, Accept, MCP-Protocol-Version, Mcp-Session-Id, Last-Event-ID"
  MCP_CORS_EXPOSE = "WWW-Authenticate, Mcp-Session-Id"

  included do
    before_action :set_mcp_cors
  end

  def options
    head :no_content
  end

  private

  def set_mcp_cors
    headers["Access-Control-Allow-Origin"] = "*"
    headers["Access-Control-Allow-Methods"] = MCP_CORS_METHODS
    headers["Access-Control-Allow-Headers"] = MCP_CORS_HEADERS
    headers["Access-Control-Expose-Headers"] = MCP_CORS_EXPOSE
    headers["Access-Control-Max-Age"] = "86400"
  end
end
