# frozen_string_literal: true

require "test_helper"

class McpServers::OauthControllerTest < ActionDispatch::IntegrationTest
  setup do
    McpServer.discover!
  end

  test "openid-configuration is served next to the issuer path" do
    get "/servers/teslamate/.well-known/openid-configuration"
    assert_response :success
    body = JSON.parse(response.body)
    assert body["issuer"].end_with?("/servers/teslamate")
    assert body["authorization_endpoint"].end_with?("/servers/teslamate/auth/authorize")
    assert body["token_endpoint"].end_with?("/servers/teslamate/auth/token")
    assert_includes body["code_challenge_methods_supported"], "S256"
  end

  test "openid-configuration is served at the RFC 8414 path-inserted URL" do
    get "/.well-known/openid-configuration/servers/teslamate"
    assert_response :success
    body = JSON.parse(response.body)
    assert body["issuer"].end_with?("/servers/teslamate")
  end

  test "root openid-configuration is JSON not HTML" do
    get "/.well-known/openid-configuration"
    assert_response :not_found
    assert_equal "application/json", response.media_type
    assert JSON.parse(response.body)["error"]
  end
end
