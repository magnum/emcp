# frozen_string_literal: true

require "test_helper"

class McpServers::AuthControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @server = mcp_server_for("whatsapp")
    post sign_in_path, params: { email: @user.email, password: "password123" }
  end

  test "whatsapp auth page shows pairing panel and start pairing" do
    get auth_mcp_server_path(@server)

    assert_response :success
    assert_match(/Link a WhatsApp account/, response.body)
    assert_match(/Pairing QR/, response.body)
    assert_select "input[type=submit][value='Start pairing']"
    assert_select "[data-controller='whatsapp-pairing']"
  end
end
