# frozen_string_literal: true

require "test_helper"

class McpServersControllerTest < ActionDispatch::IntegrationTest
  setup do
    ENV["API_KEY_HMAC_SECRET_KEY"] ||= "test-api-key-hmac-secret"
    @user = users(:one)
    provision_mcp_servers!(@user)
  end

  test "index requires session" do
    get mcp_servers_path
    assert_response :redirect
  end

  test "index renders for signed in user" do
    post sign_in_path, params: { email: @user.email, password: "password123" }
    get mcp_servers_path
    assert_equal "/servers", mcp_servers_path
    assert_response :success
    assert_match(/servers/, response.body)
    assert_match(/teslamate/i, response.body)
    assert_select "a", text: "Reset", count: 0
  end

  test "index filters by type and free text" do
    post sign_in_path, params: { email: @user.email, password: "password123" }
    teslamate = mcp_server_for("teslamate")
    teslamate.update!(name: "Car telemetry", description: "work fleet")
    type = teslamate.mcp_server_type

    get mcp_servers_path, params: { q: "fleet", mcp_server_type_id: type.id }
    assert_response :success
    assert_match(/Car telemetry/, response.body)
    refute_match(/>HEY</, response.body)
    assert_select "a[href=?]", mcp_servers_path, text: "Reset"

    get mcp_servers_path, params: { q: "does-not-exist" }
    assert_response :success
    assert_match(/No servers match/, response.body)
  end

  test "create builds an instance for the current user" do
    post sign_in_path, params: { email: @user.email, password: "password123" }
    type = McpServerType.fetch!("hey")

    assert_difference -> { @user.mcp_servers.count }, 1 do
      post mcp_servers_path, params: {
        mcp_server: { mcp_server_type_id: type.id, name: "HEY work", description: "office", tag_list: "work" }
      }
    end
    server = @user.mcp_servers.order(:id).last
    assert_equal "HEY work", server.name
    assert_equal [ "work" ], server.tag_list
    assert_redirected_to auth_mcp_server_path(server)
  end
end
