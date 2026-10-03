# frozen_string_literal: true

require "test_helper"

class McpServers::AuthControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @server = mcp_server_for("whatsapp")
    post sign_in_path, params: { email: @user.email, password: "password123" }
  end

  test "whatsapp auth page shows the saved bridge url and not the token" do
    previous_url = ENV["WHATSAPP_BRIDGE_URL"]
    previous_token = ENV["WHATSAPP_BRIDGE_TOKEN"]
    ENV.delete("WHATSAPP_BRIDGE_URL")
    ENV.delete("WHATSAPP_BRIDGE_TOKEN")
    @server.update!(credentials: {
      "WHATSAPP_BRIDGE_URL" => "http://bridge.internal:8080",
      "WHATSAPP_BRIDGE_TOKEN" => "bridge-token-value",
    }.to_json)

    get auth_mcp_server_path(@server)

    assert_response :success
    assert_select "input[name='whatsapp_bridge_url'][value='http://bridge.internal:8080']"
    assert_select "input[name='whatsapp_bridge_token'][value='bridge-token-value']", count: 0
    assert_match(/server page/, response.body)
  ensure
    previous_url ? ENV["WHATSAPP_BRIDGE_URL"] = previous_url : ENV.delete("WHATSAPP_BRIDGE_URL")
    previous_token ? ENV["WHATSAPP_BRIDGE_TOKEN"] = previous_token : ENV.delete("WHATSAPP_BRIDGE_TOKEN")
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
