# frozen_string_literal: true

require "test_helper"

class OnePasswordServerTest < ActiveSupport::TestCase
  setup do
    McpServer.discover!
    @server = McpServer.fetch!("onepassword")
    @server.update!(allow_write: true)
  end

  test "catalog covers read and gated write families" do
    names = @server.tool_catalog.map { |tool| tool[:name] }

    %w[
      onepassword_whoami onepassword_ratelimit
      onepassword_vault_list onepassword_vault_get
      onepassword_item_list onepassword_item_get onepassword_read
      onepassword_document_list onepassword_document_get
      onepassword_item_create onepassword_item_edit onepassword_item_delete
      onepassword_vault_create onepassword_vault_delete
    ].each do |name|
      assert_includes names, name
    end
  end

  test "mutations are write tools" do
    %w[
      onepassword_item_create onepassword_item_edit onepassword_item_delete
      onepassword_vault_create onepassword_vault_delete
    ].each do |name|
      assert tool(name)[:write], "#{name} must be write"
    end

    %w[onepassword_whoami onepassword_item_get onepassword_read].each do |name|
      refute tool(name)[:write], "#{name} must be read-only"
    end
  end

  test "read rejects references that are not op://" do
    result = @server.call_tool("onepassword_read", { "reference" => "https://example.com" })
    text = result.structured_content.fetch("text")
    assert_match(/op:\/\//, text)
    assert_match(/ERROR/, text)
  end

  test "call_tool writes an activity log line" do
    Current.remote_ip = "198.51.100.10"
    Current.user = users(:one)
    McpActivityLog.reset!
    FileUtils.rm_rf(McpActivityLog.directory)

    @server.call_tool("onepassword_read", { "reference" => "https://example.com" })
    McpActivityLog.reset!

    line = File.read(McpActivityLog.path_for("onepassword"))
    assert_includes line, "server=onepassword"
    assert_includes line, "tool=onepassword_read"
    assert_includes line, "status=ko"
    assert_includes line, "ip=198.51.100.10"
    assert_includes line, users(:one).email
  ensure
    Current.reset
    McpActivityLog.reset!
    FileUtils.rm_rf(McpActivityLog.directory)
  end

  test "auth form stores OP_SERVICE_ACCOUNT_TOKEN" do
    assert_equal %w[OP_SERVICE_ACCOUNT_TOKEN], @server.credential_env_keys
    field = @server.auth_fields.find { |entry| entry[:name] == "op_service_account_token" }
    assert_equal "password", field[:type]
    assert_equal "OP_SERVICE_ACCOUNT_TOKEN", field[:env]
  end

  test "apply_credentials requires a token" do
    ENV.delete("OP_SERVICE_ACCOUNT_TOKEN")
    @server.clear_credentials!

    error = assert_raises(RuntimeError) { @server.apply_credentials("op_service_account_token" => "") }
    assert_match(/OP_SERVICE_ACCOUNT_TOKEN/, error.message)
  ensure
    ENV.delete("OP_SERVICE_ACCOUNT_TOKEN")
  end

  private

  def tool(name)
    @server.tool_catalog.find { |entry| entry[:name] == name } || flunk("missing tool #{name}")
  end
end
