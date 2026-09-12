# frozen_string_literal: true

require "test_helper"

class Admin::McpServersControllerTest < ActionDispatch::IntegrationTest
  setup do
    McpServer.discover!
    @user = users(:one)
    @user.add_role(:admin)
    post sign_in_path, params: { email: @user.email, password: "password123" }
  end

  test "index renders without instantiating a runtime client on the base class" do
    get admin_mcp_servers_path

    assert_response :success
    assert_match(/hey/i, response.body)
  end
end
