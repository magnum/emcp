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
    assert_match(/teslamate/i, response.body)
    assert_select "a[href=?]", mcp_servers_path, text: "Servers"
    assert_select "a[href=?]", contexts_path, text: "Contexts"
    assert_select "a.underline", text: "Servers"
    assert_select "option", text: "Context", count: 0
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

  test "index ANDs text search with tag: filters" do
    post sign_in_path, params: { email: @user.email, password: "password123" }
    hey = mcp_server_for("hey")
    hey.update!(name: "server1", description: "desk", tag_list: "tag1")
    teslamate = mcp_server_for("teslamate")
    teslamate.update!(name: "server1", description: "desk", tag_list: "other")

    get mcp_servers_path, params: { q: "server1 tag:tag1" }
    assert_response :success
    assert_match(/server1/, response.body)
    assert_select "h2", text: /server1/, count: 1
    refute_match(/Car telemetry/, response.body)
  end

  test "index lists current user tags that search via query string" do
    post sign_in_path, params: { email: @user.email, password: "password123" }
    mcp_server_for("hey").update!(tag_list: "work, home")
    mcp_server_for("teslamate").update!(tag_list: "fleet, work")
    other = mcp_server_for("hey", user: users(:two))
    other.update!(tag_list: "secret")

    get mcp_servers_path
    assert_response :success
    assert_select "a[href=?]", mcp_servers_path(q: "tag:work"), text: "work", count: 1
    assert_select "a[href=?]", mcp_servers_path(q: "tag:home"), text: "home", count: 1
    assert_select "a[href=?]", mcp_servers_path(q: "tag:fleet"), text: "fleet", count: 1
    assert_select "a", text: "secret", count: 0

    get mcp_servers_path, params: { q: "tag:work", mcp_server_type_id: McpServerType.fetch!("hey").id }
    assert_response :success
    assert_select "a[href=?]", mcp_servers_path(q: "tag:home", mcp_server_type_id: McpServerType.fetch!("hey").id)
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

  test "index hides contexts" do
    post sign_in_path, params: { email: @user.email, password: "password123" }
    create_context!(name: "House")

    get mcp_servers_path
    assert_response :success
    refute_match(/House/, response.body)
    assert_select "a.underline", text: "Servers"
  end

  test "created service state tooltip asks to click instead of showing json" do
    post sign_in_path, params: { email: @user.email, password: "password123" }
    server = mcp_server_for("hey")
    assert server.created?

    get mcp_server_path(server)

    assert_response :success
    assert_select "[role=tooltip]", text: "Created. Not checked yet. Click to update the status."
  end

  test "show places the service state icon under the type and prints service info" do
    post sign_in_path, params: { email: @user.email, password: "password123" }
    server = mcp_server_for("hey")
    server.update!(service_info: { "connected" => false, "detail" => { "error" => "session rejected" } })
    server.disconnect!

    get mcp_server_path(server)

    assert_response :success
    assert_select "h1", text: server.name
    assert_select "form[action=?] button[aria-label=?]", service_state_mcp_server_path(server), "Run service check"
    assert_select "[role=tooltip]", text: /Disconnected/
    assert_match(/session rejected/, response.body)
    assert_match(/MCP endpoint/, response.body)
  end

  test "clicking the service state badge runs the probe and replaces the badge" do
    post sign_in_path, params: { email: @user.email, password: "password123" }
    server = mcp_server_for("hey")
    original = Emcp::Servers::Hey::Server.instance_method(:emcp_service_info)
    Emcp::Servers::Hey::Server.define_method(:emcp_service_info) { { connected: true, accounts: 1 } }

    post service_state_mcp_server_path(server), as: :turbo_stream

    assert_response :success
    assert_match(/connected/, response.body)
    assert_match(/turbo-stream/, response.body)
    assert server.reload.connected?
    assert_equal true, server.service_info["connected"]
  ensure
    Emcp::Servers::Hey::Server.define_method(:emcp_service_info, original) if original
  end

  test "destroying a context returns to contexts" do
    post sign_in_path, params: { email: @user.email, password: "password123" }
    context = create_context!(name: "House")

    delete mcp_server_path(context)
    assert_redirected_to contexts_path
  end
end
