# frozen_string_literal: true

require "test_helper"

class PurgeWebhooksJobTest < ActiveJob::TestCase
  setup do
    @server = mcp_server_for("whatsapp")
    @hook = @server.whatsapp_hooks.create!(
      url: "https://example.com/hook",
      secret: "supersecret",
    )
    @previous = ENV["WEBHOOK_RETAIN"]
  end

  teardown do
    if @previous.nil?
      ENV.delete("WEBHOOK_RETAIN")
    else
      ENV["WEBHOOK_RETAIN"] = @previous
    end
  end

  test "retain_seconds defaults to one week" do
    ENV.delete("WEBHOOK_RETAIN")
    assert_equal 604_800, Webhook.retain_seconds
  end

  test "deletes calls older than WEBHOOK_RETAIN and keeps the receipt" do
    ENV["WEBHOOK_RETAIN"] = "604800"
    stale = @hook.webhook!(:post, @hook.url, body: "{}", headers: {}, async: true)
    receipt = @hook.receipts.create!(message_id: "m-old", outcome: "sent", webhook: stale)
    stale.update_columns(created_at: 8.days.ago)
    fresh = @hook.webhook!(:post, @hook.url, body: "{}", headers: {}, async: true)

    PurgeWebhooksJob.perform_now

    assert_nil Webhook.find_by(id: stale.id)
    assert Webhook.exists?(fresh.id)
    assert_nil receipt.reload.webhook_id
    assert receipt.sent?
  end
end
