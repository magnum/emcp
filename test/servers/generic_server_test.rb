# frozen_string_literal: true

require "test_helper"

class GenericServerTest < ActiveSupport::TestCase
  setup do
    @server = mcp_server_for("generic")
    @calls = []
    @server.instance_variable_set(:@client, fake_client)
    @server.instance_variable_set(:@configured, false)
    @server.instance_variable_set(:@tools, [])
  end

  test "a new generic server sorts ahead of the other servers" do
    hey = mcp_server_for("hey")

    assert_equal(-1, @server.ord)
    assert_equal 0, hey.ord
    assert_equal(-1, Emcp::Servers::Generic::Server.ord)
    assert_equal 0, Emcp::Servers::Hey::Server.ord
  end

  test "fetch_auth_status reports the remote server without the token" do
    status = @server.fetch_auth_status

    assert_equal true, status[:authenticated]
    assert_equal 1, status[:tools]
    assert_equal "wrks", status[:server]
    assert_nil status[:token]
  end

  test "remote tools are forwarded and stay closed until allow write is on" do
    ping = @server.tool_catalog.find { |tool| tool[:name] == "ping" }

    assert_equal "object", ping.dig(:input_schema, :type)
    assert_equal "string", ping.dig(:input_schema, :properties, :q, :type)
    assert_equal true, ping[:write]
    assert_equal false, ping[:enabled]
    assert_raises(SecurityError) { @server.call_tool("ping", { "q" => "hi" }) }

    @server.update!(allow_write: true)
    result = @server.call_tool("ping", { "q" => "hi" })

    assert_equal "pong", result.content.first[:text]
    assert_equal [ "ping", { "q" => "hi" } ], @calls.last
  end

  test "replace_client! does not connect" do
    @server.replace_client!

    assert_instance_of Emcp::Servers::Generic::Client, @server.instance_variable_get(:@client)
    assert_empty @server.instance_variable_get(:@client).tools
  end

  private

  def fake_client
    calls = @calls
    Class.new do
      define_method(:status) { { "tools" => 1, "server" => "wrks" } }
      define_method(:tools) do
        [ {
          "name" => "ping",
          "description" => "Ping the remote server",
          "inputSchema" => {
            "type" => "object",
            "properties" => { "q" => { "type" => "string" } },
            "required" => [ "q" ],
          },
        } ]
      end
      define_method(:call_tool) do |name, arguments|
        calls << [ name, arguments ]
        { "content" => [ { "type" => "text", "text" => "pong" } ], "isError" => false }
      end
    end.new
  end
end
