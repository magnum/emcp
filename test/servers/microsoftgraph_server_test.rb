# frozen_string_literal: true

require "test_helper"

class MicrosoftGraphServerTest < ActiveSupport::TestCase
  FakeClient = Struct.new(:calls, keyword_init: true) do
    def initialize(calls: [])
      super
    end

    def get(path, query: {})
      calls << [:get, path, query]
      { status: 200, body: { "id" => "site-1", "displayName" => "Marketing" } }
    end

    def post(path, body:, query: {})
      calls << [:post, path, body]
      { status: 201, body: body }
    end

    def patch(path, body:, query: {})
      calls << [:patch, path, body]
      { status: 200, body: body }
    end

    def delete(path, query: {})
      calls << [:delete, path]
      { status: 204, body: nil }
    end
  end

  setup do
    @server = mcp_server_for("microsoftgraph")
    @server.update!(allow_write: true)
    @fake = FakeClient.new
    @server.instance_variable_set(:@client, @fake)
  end

  test "catalog includes sharepoint read and write tools" do
    names = @server.tool_catalog.map { |tool| tool[:name] }
    %w[
      microsoftgraph_me microsoftgraph_sites_search microsoftgraph_site
      microsoftgraph_site_update microsoftgraph_lists microsoftgraph_list_items
      microsoftgraph_list_item_create microsoftgraph_list_item_update
      microsoftgraph_list_item_delete microsoftgraph_drives microsoftgraph_request
    ].each do |name|
      assert_includes names, name
    end
    assert @server.tool_catalog.find { |tool| tool[:name] == "microsoftgraph_site_update" }[:write]
    refute @server.tool_catalog.find { |tool| tool[:name] == "microsoftgraph_site" }[:write]
  end

  test "site update patches the graph site" do
    @server.call_tool("microsoftgraph_site_update", { "site_id" => "site-1", "display_name" => "New name" })

    assert_equal [:patch, "/sites/site-1", { displayName: "New name" }], @fake.calls.last
  end

  test "site lookup uses hostname and path" do
    @server.call_tool("microsoftgraph_site", { "hostname" => "contoso.sharepoint.com", "path" => "sites/Marketing" })

    assert_equal [:get, "/sites/contoso.sharepoint.com:/sites/Marketing", {}], @fake.calls.last
  end

  test "list item update patches fields" do
    @server.call_tool(
      "microsoftgraph_list_item_update",
      { "site_id" => "site-1", "list_id" => "list-1", "item_id" => "7", "fields" => { "Title" => "Hello" } },
    )

    assert_equal [:patch, "/sites/site-1/lists/list-1/items/7/fields", { "Title" => "Hello" }], @fake.calls.last
  end

  test "generic request rejects unknown methods and non-graph paths" do
    assert_raises(RuntimeError) do
      @server.call_tool("microsoftgraph_request", { "method" => "TRACE", "path" => "/me" })
    end
    error = assert_raises(Emcp::Servers::MicrosoftGraph::Client::Error) do
      Emcp::Servers::MicrosoftGraph::Client.new(token: "token").get("https://evil.example/me")
    end
    assert_match(/Graph path/, error.message)
  end

  test "write tools stay disabled when allow_write is false" do
    @server.update!(allow_write: false)

    assert_raises(SecurityError) do
      @server.call_tool("microsoftgraph_site_update", { "site_id" => "site-1", "display_name" => "Nope" })
    end
  end

  test "oauth authorize url targets the tenant token endpoint family" do
    with_env(
      "MICROSOFTGRAPH_CLIENT_ID" => "app-id",
      "MICROSOFTGRAPH_TENANT_ID" => "contoso.onmicrosoft.com",
      "MICROSOFTGRAPH_ALLOW_WRITE" => nil,
    ) do
      @server.update!(allow_write: true)
      url = @server.oauth_call(callback_url: "https://emcp.example/callback", state: "state-1")[:authorization_url]
      assert_includes url, "https://login.microsoftonline.com/contoso.onmicrosoft.com/oauth2/v2.0/authorize"
      assert_includes url, "Sites.ReadWrite.All"
      assert_includes url, "offline_access"
    end
  end

  private

  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
