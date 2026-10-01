# frozen_string_literal: true

require "test_helper"

class Admin::McpServersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @user.add_role(:admin)
    provision_mcp_servers!(@user)
    post sign_in_path, params: { email: @user.email, password: "password123" }
  end

  test "index renders without instantiating a runtime client on the base class" do
    get admin_mcp_servers_path

    assert_response :success
    assert_match(/hey/i, response.body)
  end

  test "admin can destroy another user's server from administrate" do
    other_server = mcp_server_for("hey", user: users(:two))

    get admin_mcp_server_path(other_server)
    assert_response :success
    assert_select "form[action=?]", admin_mcp_server_path(other_server) do
      assert_select "input[name=_method][value=delete]"
    end

    assert_difference -> { McpServer.count }, -1 do
      delete admin_mcp_server_path(other_server)
    end
    assert_redirected_to admin_mcp_servers_path
    refute McpServer.exists?(other_server.id)
  end

  test "admin sees destroy on the server index for STI instances" do
    other_server = mcp_server_for("hey", user: users(:two))

    get admin_mcp_servers_path
    assert_response :success
    assert_select "form[action=?]", admin_mcp_server_path(other_server) do
      assert_select "input[name=_method][value=delete]"
    end
  end

  test "non-admin cannot destroy another user's server from administrate" do
    @user.remove_role(:admin)
    other_server = mcp_server_for("hey", user: users(:two))

    assert_no_difference -> { McpServer.count } do
      delete admin_mcp_server_path(other_server)
    end
    assert_response :not_found
    assert McpServer.exists?(other_server.id)
  end
end
