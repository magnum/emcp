# frozen_string_literal: true

require "test_helper"

class McpServers::ContextMembershipsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @hey = mcp_server_for("hey")
    @context = create_context!(name: "House")
    post sign_in_path, params: { email: @user.email, password: "password123" }
  end

  test "create context redirects to the hub page instead of auth" do
    assert_difference -> { @user.mcp_servers.count }, 1 do
      post contexts_path, params: {
        mcp_server: { name: "Work", description: "office" }
      }
    end
    context = @user.mcp_servers.order(:id).last
    assert context.context?
    assert_redirected_to mcp_server_path(context)
  end

  test "show lists memberships and the context MCP url" do
    @context.context_memberships.create!(mcp_server: @hey)
    get mcp_server_path(@context)
    assert_response :success
    assert_match @context.mcp_url, response.body
    assert_match @hey.name, response.body
    assert_select "form[action=?]", mcp_server_context_memberships_path(@context)
  end

  test "add pause and remove a proxied server" do
    assert_difference -> { @context.context_memberships.count }, 1 do
      post mcp_server_context_memberships_path(@context), params: {
        context_membership: { mcp_server_id: @hey.id }
      }
    end
    membership = @context.context_memberships.find_by!(mcp_server: @hey)
    assert membership.active?

    patch mcp_server_context_membership_path(@context, membership), params: {
      context_membership: { active: false }
    }
    refute membership.reload.active?

    assert_difference -> { @context.context_memberships.count }, -1 do
      delete mcp_server_context_membership_path(@context, membership)
    end
  end

  test "context MCP alias requires a bearer and answers initialize" do
    client = @context.mcp_oauth_clients.create!(
      client_id: SecureRandom.uuid,
      redirect_uris: [ "https://chatgpt.com/aip/callback" ],
      token_endpoint_auth_method: "none",
      grant_types: %w[authorization_code refresh_token],
      response_types: [ "code" ],
      client_id_issued_at: Time.now.to_i,
    )
    token = @context.mcp_oauth_access_tokens.create!(
      mcp_oauth_client: client,
      token: "emcp_#{SecureRandom.hex(16)}",
      scope: "emcp:context:#{@context.id}",
      expires_at: 1.hour.from_now,
    ).token

    post context_host_mcp_path(@context),
         params: { jsonrpc: "2.0", id: 1, method: "initialize", params: {} }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :unauthorized

    post context_host_mcp_path(@context),
         params: {
           jsonrpc: "2.0",
           id: 1,
           method: "initialize",
           params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "test", version: "1.0" } },
         }.to_json,
         headers: {
           "CONTENT_TYPE" => "application/json",
           "AUTHORIZATION" => "Bearer #{token}",
         }
    assert_includes [ 200, 202 ], response.status
  end
end
