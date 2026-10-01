# frozen_string_literal: true

require "test_helper"
require Rails.root.join("servers/context/server").to_s

class ContextServerTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @hey = mcp_server_for("hey")
    @teslamate = mcp_server_for("teslamate")
    @context = create_context!(name: "House", description: "home kit", servers: [ @hey, @teslamate ])
    @context.update!(allow_write: true)
  end

  test "is discovered and not provisioned as a default instance" do
    assert_includes McpServerType.order(:code).pluck(:code), "context"
    refute @user.mcp_servers.joins(:mcp_server_type).where.not(id: @context.id)
      .exists?(mcp_server_types: { code: "context" })
  end

  test "exposes a dedicated /context/:id MCP url" do
    assert_instance_of Emcp::Servers::Context::Server, @context
    assert_equal "#{Emcp.public_url}/context/#{@context.id}/mcp", @context.mcp_url
    assert_match %r{/context/#{@context.id}/mcp\z}, @context.oauth_protected_resource_metadata_url
  end

  test "catalog is the four proxy tools" do
    names = @context.tool_catalog.map { |tool| tool[:name] }
    assert_equal %w[context_list_servers context_get_server context_list_tools context_call_tool], names
  end

  test "list_servers reports auth and active flags" do
    listed = @context.list_proxied_servers
    hey = listed.find { |row| row[:code] == "hey" }

    assert_equal 2, listed.size
    assert_equal @hey.id, hey[:id]
    assert_equal @hey.activity_log_code, hey[:instance]
    assert_includes %w[auth noauth], hey[:auth]
    assert_equal true, hey[:active]
  end

  test "get_server and list_tools resolve by id, instance, or unique code" do
    details = @context.proxied_details(@hey.id.to_s)
    assert_equal @hey.name, details[:name]
    assert details[:tool_count].positive?

    tools = @context.proxied_tools("hey")
    names = tools[:tools].map { |tool| tool[:name] }
    assert_includes names, "hey_boxes"
  end

  test "call_tool forwards to the proxied server" do
    child = fake_child(tool: "ping", write: false)
    membership = @context.context_memberships.find_by!(mcp_server: @hey)
    @context.define_singleton_method(:find_membership!) { |_| membership }
    membership.define_singleton_method(:mcp_server) { child }

    result = @context.call_proxied_tool("hey", "ping", { "n" => 1 })
    assert_match(/\Apong:ping:\{.*n.*1/, result.content.first[:text])
  end

  test "paused membership and inactive context refuse calls" do
    @context.context_memberships.find_by!(mcp_server: @hey).update!(active: false)
    error = assert_raises(RuntimeError) { @context.call_proxied_tool("hey", "hey_boxes", {}) }
    assert_match(/paused/, error.message)

    @context.context_memberships.find_by!(mcp_server: @hey).update!(active: true)
    @context.update!(active: false)
    error = assert_raises(RuntimeError) { @context.call_proxied_tool("hey", "hey_boxes", {}) }
    assert_match(/inactive/, error.message)
  end

  test "cannot nested-proxy another context or a foreign server" do
    other = create_context!(name: "Work")
    membership = @context.context_memberships.new(mcp_server: other)
    refute membership.valid?
    assert_match(/nested-proxy/, membership.errors[:mcp_server].join)

    foreign = mcp_server_for("hey", user: users(:two))
    membership = @context.context_memberships.new(mcp_server: foreign)
    refute membership.valid?
    assert_match(/same user/, membership.errors[:mcp_server].join)
  end

  test "write tools honor the context allow_write flag" do
    @context.update!(allow_write: false)
    child = fake_child(tool: "blast", write: true)
    membership = @context.context_memberships.find_by!(mcp_server: @hey)
    @context.define_singleton_method(:find_membership!) { |_| membership }
    membership.define_singleton_method(:mcp_server) { child }

    assert_raises(SecurityError) { @context.call_proxied_tool("hey", "blast", {}) }
  end

  private

  def fake_child(tool:, write:)
    child = Object.new
    catalog = [ { name: tool, write: write } ]
    child.define_singleton_method(:tool_catalog) { catalog }
    child.define_singleton_method(:call_tool) do |name, arguments = {}|
      MCP::Tool::Response.new([ { type: "text", text: "pong:#{name}:#{arguments}" } ])
    end
    child
  end
end
