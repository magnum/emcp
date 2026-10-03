# frozen_string_literal: true

require "test_helper"
require Rails.root.join("servers/whatsapp/hook").to_s

class Admin::WebhooksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @user.add_role(:admin)
    post sign_in_path, params: { email: @user.email, password: "password123" }
    server = mcp_server_for("whatsapp", user: @user)
    @hook = server.whatsapp_hooks.create!(url: "https://example.com/hook", secret: "supersecret")
    @webhook = @hook.webhook!(:post, @hook.url, body: "{}", headers: { "Content-Type" => "application/json" }, async: true)
  end

  test "index renders a webhook attached to a whatsapp hook" do
    get admin_webhooks_path

    assert_response :success
    assert_includes response.body, "WhatsApp hook ##{@hook.id}"
    refute_includes response.body, "supersecret"
  end

  test "show renders a webhook attached to a whatsapp hook" do
    get admin_webhook_path(@webhook)

    assert_response :success
    assert_includes response.body, "WhatsApp hook ##{@hook.id}"
    refute_includes response.body, "supersecret"
  end
end
