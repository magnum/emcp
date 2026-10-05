# frozen_string_literal: true

require "test_helper"

class TelegramServerTest < ActiveSupport::TestCase
  setup do
    @server = mcp_server_for("telegram")
    @server.update!(allow_write: true)
  end

  teardown do
    %w[
      TELEGRAM_API_ID TELEGRAM_API_HASH TELEGRAM_PHONE
      TELEGRAM_BRIDGE_URL TELEGRAM_BRIDGE_TOKEN TELEGRAM_SESSION_KEY
    ].each { |key| ENV.delete(key) }
  end

  test "catalog covers the read tools and the gated writes" do
    names = @server.tool_catalog.map { |tool| tool[:name] }

    %w[
      telegram_status telegram_search_contacts telegram_list_chats
      telegram_get_chat telegram_list_messages telegram_get_message_context
      telegram_get_last_interaction telegram_list_unread
      telegram_send_message telegram_set_owner_status
    ].each do |name|
      assert_includes names, name
    end
    assert_includes tool("telegram_list_messages")[:input_schema][:required], "chat_id"
    assert tool("telegram_send_message")[:write]
    assert tool("telegram_set_owner_status")[:write]
    %w[telegram_status telegram_list_chats telegram_list_messages telegram_list_unread].each do |name|
      refute tool(name)[:write], "#{name} must be read-only"
    end
  end

  test "a context can include the telegram instance" do
    context = create_context!(servers: [ @server ])

    assert_equal [ @server.id ], context.proxied_servers.map(&:id)
    assert McpServerType.fetch!("telegram")
  end

  test "send stays disabled when writes are off" do
    @server.update!(allow_write: false)

    error = assert_raises(SecurityError) do
      @server.call_tool("telegram_send_message", { "recipient" => "ada", "message" => "hi" })
    end
    assert_match(/write method disabled/, error.message)
  end

  test "status reports the linked user" do
    install_fake!(status_payload: {
      "connected" => true,
      "logged_in" => true,
      "user_id" => "42",
      "username" => "ada",
      "name" => "Ada",
      "phone" => "39333",
    })

    result = @server.call_tool("telegram_status", {})
    data = result.structured_content.fetch("data")

    assert_equal true, data["connected"]
    assert_equal "42", data["user_id"]
    assert_equal "ada", data["username"]
  end

  test "set owner status updates every webhook" do
    hook = @server.telegram_hooks.create!(
      url: "https://example.com/hook",
      secret: "supersecret",
      secret_header: "Authorization",
    )
    refute hook.enabled?

    result = @server.call_tool("telegram_set_owner_status", { "status" => "away" })
    data = result.structured_content.fetch("data")

    assert_equal "away", hook.reload.owner_status
    assert_equal [ { "id" => hook.id, "owner_status" => "away" } ], data
  end

  test "a login code is submitted to the live bridge and is not stored" do
    calls = []
    fake = Object.new
    fake.define_singleton_method(:ensure_bridge!) { calls << :ensure }
    fake.define_singleton_method(:restart_bridge!) { calls << :restart }
    fake.define_singleton_method(:submit_code!) { |code| calls << [ :code, code ] }
    fake.define_singleton_method(:submit_password!) { |password| calls << [ :password, password ] }
    @server.define_singleton_method(:replace_client!) { @client = fake }

    assert @server.apply_credentials(
      "telegram_api_id" => "1000",
      "telegram_api_hash" => "hashhash",
      "telegram_phone" => "+39 333 111",
      "telegram_code" => "12345",
    )

    assert_equal [ :ensure, [ :code, "12345" ] ], calls
    assert_equal "39333111", @server.credentials_hash["TELEGRAM_PHONE"]
    assert_equal 64, @server.credentials_hash["TELEGRAM_SESSION_KEY"].length
    refute @server.credentials_hash.key?("telegram_code")
  end

  private

  def tool(name)
    @server.tool_catalog.find { |entry| entry[:name] == name } || flunk("missing tool #{name}")
  end

  def install_fake!(status_payload:)
    fake = Object.new
    fake.define_singleton_method(:ensure_bridge!) { true }
    fake.define_singleton_method(:status) { status_payload }
    @server.instance_variable_set(:@client, fake)
  end
end
