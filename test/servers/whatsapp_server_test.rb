# frozen_string_literal: true

require "test_helper"

class WhatsappServerTest < ActiveSupport::TestCase
  FakeClient = Struct.new(:reachable, :status_payload, :ensure_ok, keyword_init: true) do
    def reachable? = reachable
    def unreachable_reason = "bridge is not running"
    def status = status_payload
    def ensure_bridge! = ensure_ok
    def restart_bridge! = ensure_ok
    def wait_for_pairing_code!(timeout: 25) = true
    def stop_bridge!; end
    def logout = { "success" => true }
  end

  setup do
    @server = mcp_server_for("whatsapp")
    @server.update!(allow_write: true)
  end

  test "catalog covers read tools and gated send" do
    names = @server.tool_catalog.map { |tool| tool[:name] }

    %w[
      whatsapp_status whatsapp_search_contacts whatsapp_list_chats
      whatsapp_get_chat whatsapp_get_direct_chat_by_contact
      whatsapp_get_contact_chats whatsapp_list_messages
      whatsapp_get_message_context whatsapp_get_last_interaction
      whatsapp_send_message
    ].each do |name|
      assert_includes names, name
    end
  end

  test "send is a write tool and reads are not" do
    assert tool("whatsapp_send_message")[:write]
    %w[whatsapp_status whatsapp_list_chats whatsapp_list_messages].each do |name|
      refute tool(name)[:write], "#{name} must be read-only"
    end
  end

  test "auth form uses bridge url and token" do
    assert_equal %w[WHATSAPP_BRIDGE_URL WHATSAPP_BRIDGE_TOKEN], @server.credential_env_keys
    url = @server.auth_fields.find { |entry| entry[:name] == "whatsapp_bridge_url" }
    token = @server.auth_fields.find { |entry| entry[:name] == "whatsapp_bridge_token" }
    assert_equal "text", url[:type]
    assert_equal "WHATSAPP_BRIDGE_URL", url[:env]
    assert_equal "password", token[:type]
    assert_equal "WHATSAPP_BRIDGE_TOKEN", token[:env]
  end

  test "fetch_auth_status is unauthenticated when the bridge is down" do
    install_fake_client!(reachable: false, status_payload: {})

    status = @server.fetch_auth_status
    refute status[:authenticated]
    assert_match(/bridge is not running/, status[:error])
  end

  test "fetch_auth_status is authenticated when the bridge is linked" do
    install_fake_client!(
      reachable: true,
      status_payload: {
        "connected" => true,
        "logged_in" => true,
        "jid" => "393331234567@s.whatsapp.net",
        "push_name" => "Ada"
      },
    )

    status = @server.fetch_auth_status
    assert status[:authenticated]
    assert_equal "393331234567@s.whatsapp.net", status[:jid]
    assert_equal "Ada", status[:push_name]
  end

  test "fetch_auth_status exposes pairing QR png" do
    install_fake_client!(
      reachable: true,
      status_payload: {
        "pairing" => true,
        "qr_png_base64" => "abc123",
        "qr" => "2@example"
      },
    )

    status = @server.fetch_auth_status
    refute status[:authenticated]
    assert status[:pairing]
    assert_equal "abc123", status[:qr_png_base64]
    assert_equal "2@example", status[:qr]
  end

  test "apply_credentials generates a token and starts the bundled bridge" do
    fake = FakeClient.new(reachable: true, status_payload: {}, ensure_ok: true)
    @server.define_singleton_method(:replace_client!) { @client = fake }

    assert @server.apply_credentials("whatsapp_bridge_url" => "", "whatsapp_bridge_token" => "")
    token = @server.credentials_hash["WHATSAPP_BRIDGE_TOKEN"]
    assert token.present?
    assert_equal 48, token.length
  end

  test "send_message stays disabled when writes are off" do
    @server.update!(allow_write: false)

    error = assert_raises(SecurityError) do
      @server.call_tool("whatsapp_send_message", { "recipient" => "393331234567", "message" => "hi" })
    end
    assert_match(/write method disabled/, error.message)
  end

  private

  def tool(name)
    @server.tool_catalog.find { |entry| entry[:name] == name } || flunk("missing tool #{name}")
  end

  def install_fake_client!(reachable:, status_payload:)
    fake = FakeClient.new(reachable: reachable, status_payload: status_payload, ensure_ok: true)
    @server.instance_variable_set(:@client, fake)
  end
end
