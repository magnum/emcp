# frozen_string_literal: true

require "test_helper"

class McpServerTest < ActiveSupport::TestCase
  setup do
    provision_mcp_servers!
  end

  test "discovers registered integrations" do
    codes = McpServerType.order(:code).pluck(:code)
    assert_includes codes, "hey"
    assert_includes codes, "teslamate"
    assert_includes codes, "toggltrack"
    assert_includes codes, "onepassword"
  end

  test "sti fetch returns concrete class" do
    server = mcp_server_for("teslamate")
    assert_instance_of Emcp::Servers::TeslaMate::Server, server
  end

  test "token_refresh_in_minutes blank disables scheduled refresh" do
    server = mcp_server_for("hey")
    server.update!(token_refresh_in_minutes: "")
    assert_nil server.reload.token_refresh_in_minutes
    refute server.token_refresh_enabled?

    server.update!(token_refresh_in_minutes: 60)
    assert_equal 60, server.token_refresh_in_minutes
    assert server.token_refresh_enabled?
  end

  test "service_token_refresh_in_minutes blank disables provider refresh schedule" do
    server = mcp_server_for("hey")
    server.update!(service_token_refresh_in_minutes: "")
    assert_nil server.reload.service_token_refresh_in_minutes
    refute server.service_token_refresh_enabled?

    server.update!(service_token_refresh_in_minutes: 90)
    assert_equal 90, server.service_token_refresh_in_minutes
    assert server.service_token_refresh_enabled?
  end

  test "provider defaults for service_token_refresh_in_minutes" do
    assert_equal 1_440, Emcp::Servers::GoogleWorkspace::Server.default_service_token_refresh_in_minutes
    assert_equal 1_320, Emcp::Servers::FattureInCloud::Server.default_service_token_refresh_in_minutes
    assert_equal 90, Emcp::Servers::Twitter::Server.default_service_token_refresh_in_minutes
    assert_equal 90, Emcp::Servers::Bluesky::Server.default_service_token_refresh_in_minutes
    assert_nil Emcp::Servers::Hey::Server.default_service_token_refresh_in_minutes
    assert_equal 10_080, Emcp::Servers::Basecamp::Server.default_service_token_refresh_in_minutes
  end

  test "teslamate tool catalog includes reports and run_sql" do
    server = mcp_server_for("teslamate")
    names = server.tool_catalog.map { |tool| tool[:name] }
    assert_includes names, "get_battery_capacity_trend"
    assert_includes names, "teslamate_run_sql"
    assert_includes names, "teslamate_get_database_schema"
    server.tool_catalog.each do |tool|
      assert_equal "object", tool[:output_schema][:type], "#{tool[:name]} missing output schema"
    end
  end

  test "server/discover advertises MCP 2026-07-28 for ChatGPT web" do
    server = mcp_server_for("teslamate")
    payload = JSON.parse(
      server.handle_mcp_json({
        jsonrpc: "2.0",
        id: "teslamate",
        method: "server/discover",
        params: {
          _meta: {
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientInfo" => { name: "openai-mcp", version: "1.0.0" },
          },
        },
      }.to_json),
    )
    result = payload.fetch("result")
    assert_equal "teslamate", payload["id"]
    assert_equal "complete", result["resultType"]
    assert_includes result.fetch("supportedVersions"), "2026-07-28"
    assert result.dig("capabilities", "tools")
    refute result.dig("capabilities", "tools", "listChanged")
    assert_equal "teslamate", result.dig("_meta", "io.modelcontextprotocol/serverInfo", "name")
    assert_equal 0, result["ttlMs"]
    assert_equal "private", result["cacheScope"]
  end

  test "tools/list includes object schemas and ChatGPT-required annotations" do
    server = mcp_server_for("teslamate")
    payload = JSON.parse(
      server.handle_mcp_json({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }.to_json),
    )
    listed = payload.dig("result", "tools")
    assert listed.present?

    listed.each do |tool|
      schema = tool.fetch("inputSchema")
      assert_equal "object", schema["type"], "#{tool["name"]} inputSchema.type must be object"
      assert schema.key?("properties"), "#{tool["name"]} must declare properties"
      output = tool.fetch("outputSchema")
      assert_equal "object", output["type"], "#{tool["name"]} outputSchema.type must be object"
      assert output.dig("properties", "text"), "#{tool["name"]} outputSchema must describe text"
      annotations = tool.fetch("annotations")
      %w[readOnlyHint destructiveHint openWorldHint].each do |key|
        assert_includes [true, false], annotations[key], "#{tool["name"]} missing boolean #{key}"
      end
    end
  end

  test "registered servers implement the runtime contract" do
    McpServer.integration_classes.each do |klass|
      server = mcp_server_for(klass.server_id)
      assert server.instance_variable_get(:@client),
        "#{klass.server_id} must implement replace_client!"
      assert_kind_of Array, server.credential_env_keys
      server.tool_catalog.each do |tool|
        assert_equal "object", tool.dig(:output_schema, :type),
          "#{klass.server_id} #{tool[:name]} must declare an object outputSchema"
      end
    end
  end

  test "unimplemented contract methods raise NotImplementedError" do
    server = Class.new(McpServer).allocate

    assert_raises(NotImplementedError) { server.configure_tools }
    assert_raises(NotImplementedError) { server.apply_credentials({}) }
    assert_raises(NotImplementedError) { server.clear_credentials! }
    assert_raises(NotImplementedError) { server.fetch_auth_status }
    assert_raises(NotImplementedError) { server.replace_client! }
    assert_raises(NotImplementedError) { server.credential_env_keys }
    assert_raises(NotImplementedError) { server.oauth_call(callback_url: "/", state: "s") }
    assert_raises(NotImplementedError) { server.oauth_exchange(callback_url: "/", params: {}) }
  end

  test "base McpServer can initialize without a runtime client" do
    server = McpServer.new(name: "Orphan", type: "McpServer")

    assert_instance_of McpServer, server
    assert_nil server.instance_variable_get(:@client)
  end

  test "mcp_url includes type code and instance id" do
    server = mcp_server_for("hey")
    assert_equal "#{Emcp.public_url}/servers/hey/#{server.id}/mcp", server.mcp_url
    assert_equal McpServer.fetch!("hey", server.id), server
  end

  test "tags are scoped to the owning user" do
    owner = users(:one)
    other = users(:two)
    mine = mcp_server_for("hey", user: owner)
    theirs = mcp_server_for("hey", user: other)

    mine.update!(tag_list: "work, personal")
    theirs.update!(tag_list: "home")

    assert_equal %w[personal work], mine.reload.tag_list.sort
    assert_includes mine.available_tag_names, "work"
    refute_includes theirs.available_tag_names, "work"
  end
end
