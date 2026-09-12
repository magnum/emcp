# frozen_string_literal: true

require "test_helper"

class McpServers::McpControllerTest < ActionDispatch::IntegrationTest
  setup do
    @server = mcp_server_for("teslamate")
    client = @server.mcp_oauth_clients.create!(
      client_id: SecureRandom.uuid,
      redirect_uris: ["https://chatgpt.com/aip/callback"],
      token_endpoint_auth_method: "none",
      grant_types: %w[authorization_code refresh_token],
      response_types: ["code"],
      client_id_issued_at: Time.now.to_i,
    )
    @access_token = @server.mcp_oauth_access_tokens.create!(
      mcp_oauth_client: client,
      token: "emcp_#{SecureRandom.hex(16)}",
      scope: "emcp:teslamate",
      expires_at: 1.hour.from_now,
    ).token
  end

  test "mcp endpoint rejects missing bearer" do
    post instance_mcp_path(@server.code, @server.id),
         params: { jsonrpc: "2.0", id: 1, method: "initialize", params: {} }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :unauthorized
  end

  test "mcp endpoint accepts oauth bearer" do
    body = {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-03-26",
        capabilities: {},
        clientInfo: { name: "test", version: "1.0" },
      },
    }
    post instance_mcp_path(@server.code, @server.id),
         params: body.to_json,
         headers: {
           "CONTENT_TYPE" => "application/json",
           "AUTHORIZATION" => "Bearer #{@access_token}",
         }
    assert_includes [200, 202], response.status
  end

  test "mcp endpoint answers CORS preflight without auth" do
    process :options, instance_mcp_path(@server.code, @server.id),
            headers: {
              "ORIGIN" => "https://chatgpt.com",
              "ACCESS_CONTROL_REQUEST_METHOD" => "POST",
              "ACCESS_CONTROL_REQUEST_HEADERS" => "authorization,content-type",
            }
    assert_response :no_content
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
    assert_match(/POST/, response.headers["Access-Control-Allow-Methods"])
    assert_match(/Authorization/i, response.headers["Access-Control-Allow-Headers"])
  end

  test "tools/list returns teslamate actions with annotations" do
    body = { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }
    post instance_mcp_path(@server.code, @server.id),
         params: body.to_json,
         headers: {
           "CONTENT_TYPE" => "application/json",
           "AUTHORIZATION" => "Bearer #{@access_token}",
           "ORIGIN" => "https://chatgpt.com",
         }
    assert_response :success
    listed = JSON.parse(response.body).dig("result", "tools")
    assert listed.present?
    assert listed.any? { |tool| tool["name"] == "teslamate_run_sql" }
    assert listed.first.dig("annotations", "readOnlyHint")
    assert_equal "object", listed.first.dig("inputSchema", "type")
    assert_equal "object", listed.first.dig("outputSchema", "type")
    listed.each do |tool|
      assert tool["outputSchema"].present?, "#{tool["name"]} missing outputSchema"
    end
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
  end

  test "server/discover returns ChatGPT 2026-07-28 shape" do
    body = {
      jsonrpc: "2.0",
      id: "teslamate",
      method: "server/discover",
      params: {
        _meta: {
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientInfo" => { name: "openai-mcp", version: "1.0.0" },
        },
      },
    }
    post instance_mcp_path(@server.code, @server.id),
         params: body.to_json,
         headers: {
           "CONTENT_TYPE" => "application/json",
           "AUTHORIZATION" => "Bearer #{@access_token}",
         }
    assert_response :success
    result = JSON.parse(response.body).fetch("result")
    assert_equal "complete", result["resultType"]
    assert_includes result.fetch("supportedVersions"), "2026-07-28"
    assert result.dig("capabilities", "tools")
  end

  test "modern tools/list stamps resultType for ChatGPT" do
    body = {
      jsonrpc: "2.0",
      id: 2,
      method: "tools/list",
      params: {
        _meta: {
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientInfo" => { name: "openai-mcp", version: "1.0.0" },
        },
      },
    }
    post instance_mcp_path(@server.code, @server.id),
         params: body.to_json,
         headers: {
           "CONTENT_TYPE" => "application/json",
           "AUTHORIZATION" => "Bearer #{@access_token}",
         }
    assert_response :success
    result = JSON.parse(response.body).fetch("result")
    assert result["tools"].present?
    assert_equal "complete", result["resultType"]
    assert_equal 0, result["ttlMs"]
    assert_equal "private", result["cacheScope"]
  end

  test "tools/call appends an activity log line" do
    McpActivityLog.reset!
    FileUtils.rm_rf(McpActivityLog.directory)

    post instance_mcp_path(@server.code, @server.id),
         params: {
           jsonrpc: "2.0",
           id: 9,
           method: "tools/call",
           params: { name: "teslamate_get_database_schema", arguments: {} },
         }.to_json,
         headers: {
           "CONTENT_TYPE" => "application/json",
           "AUTHORIZATION" => "Bearer #{@access_token}",
         }
    assert_includes [200, 202], response.status
    McpActivityLog.reset!

    line = File.read(McpActivityLog.path_for(@server.activity_log_code))
    assert_includes line, "server=#{@server.activity_log_code}"
    assert_includes line, "tool=teslamate_get_database_schema"
    assert_match(/status=(ok|ko)/, line)
    assert_includes line, "ip="
  ensure
    McpActivityLog.reset!
    FileUtils.rm_rf(McpActivityLog.directory)
  end
end
