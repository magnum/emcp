# frozen_string_literal: true

require "test_helper"

class TelegramInboundMessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @server = mcp_server_for("telegram", user: @user)
    @server.update!(credentials: { "TELEGRAM_BRIDGE_TOKEN" => "bridge-token" }.to_json)
  end

  test "rejects a missing token and accepts a live message" do
    post inbound_messages_mcp_server_path(@server), params: payload, as: :json
    assert_response :unauthorized

    hook = @server.telegram_hooks.create!(
      url: "https://example.com/hook",
      secret: "supersecret",
      secret_header: "Authorization",
      enabled: true,
      debounce_minutes: 0,
    )
    assert_enqueued_jobs 1, only: WebhookJob do
      post inbound_messages_mcp_server_path(@server),
           params: payload,
           headers: { "X-Bridge-Token" => "bridge-token" },
           as: :json
    end
    assert_response :accepted
    assert hook.receipts.find_by!(message_id: "tg-1").sent?
  end

  test "auth page and webhook form expose linking and delivery rules" do
    post sign_in_path, params: { email: @user.email, password: "password123" }
    get auth_mcp_server_path(@server)
    assert_response :success
    assert_select "input[name='telegram_api_id']"
    assert_select "input[name='telegram_api_hash']"
    assert_select "input[name='telegram_phone']"
    assert_select "input[name='telegram_code']"
    assert_select "input[type=submit][value='Start linking']"

    get new_mcp_server_webhook_path(@server)
    assert_response :success
    assert_select "input[name='telegram_hook[enabled]']"
    assert_select "input[name='telegram_hook[chat_types][]'][value='private']"
    assert_select "input[name='telegram_hook[mentions_only]']"
    assert_select "input[name='telegram_hook[ignore_muted]']"
    assert_select "input[name='telegram_hook[ignore_channels]']"
    assert_select "select[name='telegram_hook[respond_by_status]']"
    assert_select "input[name='telegram_hook[debounce_minutes]']"
    assert_select "input[name='whatsapp_hook[url]']", count: 0

    post mcp_server_webhooks_path(@server), params: {
      telegram_hook: {
        url: "https://example.com/hook",
        secret: "supersecret",
        secret_header: "Authorization",
        enabled: "0",
        chat_ids: "42, 43",
        chat_types: [ "", "private", "group" ],
        mentions_only: "1",
        ignore_muted: "1",
        ignore_channels: "1",
        respond_by_status: "away",
        debounce_minutes: "10",
      },
    }
    assert_redirected_to mcp_server_path(@server)
    hook = @server.telegram_hooks.sole
    refute hook.enabled?
    assert_equal "42,43", hook.chat_ids
    assert_equal "private,group", hook.chat_types
    assert hook.mentions_only?
    assert_equal "away", hook.respond_by_status
    assert_equal 10, hook.debounce_minutes
  end

  private

  def payload
    {
      message_id: "tg-1",
      timestamp: "2026-10-04T15:00:00Z",
      chat_id: "42",
      chat_title: "Ada",
      chat_type: "private",
      sender_id: "7",
      sender_name: "Ada",
      is_from_me: false,
      mentions_owner: false,
      muted: false,
      text: "ciao",
    }
  end
end
