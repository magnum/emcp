# frozen_string_literal: true

module McpAuthenticatable
  extend ActiveSupport::Concern
  include ApiKeyAuthenticatable

    def authorize_mcp!
      token = bearer_token
      payload = oauth_provider.load_access_token(token)
      unless payload
        metadata = "#{Emcp.public_url}/.well-known/oauth-protected-resource/servers/#{mcp_server.code}/#{mcp_server.id}/mcp"
        headers["WWW-Authenticate"] =
          %(Bearer error="invalid_token", resource_metadata="#{metadata}")
        render json: { error: "invalid_token", error_description: "Authentication required" }, status: :unauthorized
        return
      end

      Current.remote_ip = request.remote_ip
      assign_mcp_actor(payload)
    end

    def assign_mcp_actor(payload)
      user = payload[:user]
      Current.user = user if user.is_a?(User)
      Current.mcp_actor =
        if Current.user
          Current.user.email
        elsif payload[:client_name].present?
          "oauth:#{payload[:client_name]}"
        elsif payload[:client_id].present?
          "oauth:#{payload[:client_id]}"
        else
          payload[:subject].presence || "-"
        end
    end

  def mcp_server
    @mcp_server ||= resolve_mcp_server
  end

  def oauth_provider
    @oauth_provider ||= McpOauthProvider.new(mcp_server)
  end

  private

  def resolve_mcp_server
    if params[:type_code].present?
      McpServer.fetch!(params[:type_code], params[:id])
    elsif current_user
      current_user.mcp_servers.find(params[:id] || params[:server_id])
    else
      McpServer.find(params[:id] || params[:server_id])
    end
  end
end
