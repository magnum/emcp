# frozen_string_literal: true

require "test_helper"

class WhatsappInboundMessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @server = mcp_server_for("whatsapp", user: @user)
    @server.update!(credentials: { "WHATSAPP_BRIDGE_TOKEN" => "bridge-token" }.to_json)
    @server.whatsapp_hooks.create!(url: "https://example.com/hook", secret: "supersecret")
  end

  test "rejects a missing token" do
    post inbound_messages_mcp_server_path(@server), params: payload, as: :json
    assert_response :unauthorized
  end

  test "accepts a live message and does not render the secret" do
    assert_enqueued_jobs 1, only: WebhookJob do
      post inbound_messages_mcp_server_path(@server),
           params: payload,
           headers: { "X-Bridge-Token" => "bridge-token" },
           as: :json
    end
    assert_response :accepted

    post sign_in_path, params: { email: @user.email, password: "password123" }
    get mcp_server_path(@server)
    assert_response :success
    refute_includes response.body, "supersecret"
  end

  private

  def payload
    {
      message_id: "in-1",
      timestamp: "2026-10-03T12:00:00Z",
      chat_jid: "393331111111@s.whatsapp.net",
      is_group: false,
      is_from_me: false,
      sender_phone: "393331111111",
      type: "text",
      text: "ciao",
    }
  end
end
