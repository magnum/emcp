# frozen_string_literal: true

require "test_helper"
require Rails.root.join("servers/whatsapp/hook").to_s
require Rails.root.join("servers/whatsapp/inbound_message").to_s
require Rails.root.join("servers/whatsapp/dispatch").to_s

class WhatsappDispatchTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @server = mcp_server_for("whatsapp")
    @hook = @server.whatsapp_hooks.create!(
      url: "https://example.com/hook",
      secret: "supersecret",
      secret_header: "Authorization",
    )
  end

  test "direct chats send and plain group messages do not" do
    assert_difference -> { Webhook.count }, 1 do
      assert_enqueued_jobs 1, only: WebhookJob do
        deliver(text: "ciao", group: false)
      end
    end
    assert @hook.receipts.last.sent?
    assert_equal "mention", @hook.receipts.last.reason

    assert_no_difference -> { Webhook.count } do
      assert_no_enqueued_jobs only: WebhookJob do
        deliver(text: "ciao", group: true, mentions_owner: false, id: "g1")
      end
    end
    assert @hook.receipts.find_by(message_id: "g1").filtered?
    assert_equal "mention", @hook.receipts.find_by(message_id: "g1").reason
  end

  test "when never sends nothing and when always sends every message" do
    @hook.update!(respond_when: "never")
    assert_no_difference -> { Webhook.count } do
      deliver(text: "ciao", id: "never")
    end
    assert_equal "never", @hook.receipts.find_by!(message_id: "never").reason

    @hook.update!(respond_when: "always")
    deliver(text: "ciao", group: true, mentions_owner: false, from_me: true, id: "always")
    assert @hook.receipts.find_by!(message_id: "always").sent?
    assert_equal "always", @hook.receipts.find_by!(message_id: "always").reason
  end

  test "word matches a whole word and mention does not" do
    @hook.update!(respond_when: "mention")
    deliver(text: "hey bot", group: true, mentions_owner: false, id: "word-ignored")
    assert @hook.receipts.find_by!(message_id: "word-ignored").filtered?

    @hook.update!(respond_when: "word", consider_words: "bot")
    deliver(text: "botting", group: true, mentions_owner: true, id: "part")
    assert @hook.receipts.find_by!(message_id: "part").filtered?

    deliver(text: "hey BOT", group: true, mentions_owner: false, id: "word")
    receipt = @hook.receipts.find_by!(message_id: "word")
    assert receipt.sent?
    assert_equal "word", receipt.reason
    assert_equal [ "bot" ], JSON.parse(receipt.webhook.body)["matched_words"]
  end

  test "a custom history limit wins over the environment default" do
    @hook.update!(history_limit: 1, respond_when: "always")
    deliver(text: "one", id: "h1")
    deliver(text: "two", id: "h2")
    history = JSON.parse(@hook.receipts.find_by!(message_id: "h2").webhook.body)["history"]
    assert_equal [ "h2" ], history.map { |entry| entry["message_id"] }
  end

  test "two hooks that share a url send the message once" do
    other = @server.whatsapp_hooks.create!(
      url: @hook.url,
      secret: "anothersecret",
      respond_when: "always",
    )
    assert_difference -> { Webhook.count }, 1 do
      @server.accept_inbound_message!(inbound(text: "ciao", id: "same-url"))
    end
    receipts = [ @hook, other ].map { |hook| hook.receipts.find_by!(message_id: "same-url") }
    assert_equal 1, receipts.count(&:sent?)
    assert_equal "duplicate", receipts.find(&:filtered?).reason
  end

  test "an api send stays in history and does not fire a webhook" do
    @hook.update!(respond_when: "always")
    assert_no_difference -> { Webhook.count } do
      @server.accept_inbound_message!(inbound(text: "risposta", id: "out-1", from_me: true, skip_webhook: true))
    end
    assert_equal "api_send", @hook.receipts.find_by!(message_id: "out-1").reason

    assert_no_difference -> { Webhook.count } do
      deliver(text: "risposta", from_me: true, id: "out-1")
    end

    deliver(text: "grazie", id: "in-2")
    history = JSON.parse(@hook.receipts.find_by!(message_id: "in-2").webhook.body)["history"]
    sent = history.find { |entry| entry["message_id"] == "out-1" }
    assert_equal "risposta", sent["text"]
    assert_equal true, sent["is_from_me"]
  end

  test "status and channel posts do not send unless ticked" do
    @hook.update!(respond_when: "always")

    deliver(text: "story", id: "status-1", jid: "status@broadcast")
    assert @hook.receipts.find_by!(message_id: "status-1").filtered?
    assert_equal "status", @hook.receipts.find_by!(message_id: "status-1").reason

    deliver(text: "post", id: "news-1", jid: "120363@newsletter")
    assert_equal "newsletter", @hook.receipts.find_by!(message_id: "news-1").reason

    deliver(text: "list", id: "cast-1", jid: "120363@broadcast")
    assert_equal "broadcast", @hook.receipts.find_by!(message_id: "cast-1").reason

    deliver(text: "ciao", id: "lid-1", jid: "abc@lid")
    assert @hook.receipts.find_by!(message_id: "lid-1").sent?

    @hook.update!(chat_kinds: "direct,group,status")
    deliver(text: "story", id: "status-2", jid: "status@broadcast")
    assert @hook.receipts.find_by!(message_id: "status-2").sent?
  end

  test "the same message is not sent twice" do
    deliver(text: "ciao", id: "dup")
    assert_no_difference -> { @hook.receipts.count } do
      assert_no_enqueued_jobs only: WebhookJob do
        deliver(text: "ciao", id: "dup")
      end
    end
  end

  test "payload omits the secret" do
    deliver(text: "embot ciao", id: "body")
    body = @hook.receipts.find_by!(message_id: "body").webhook.body
    refute_includes body, @hook.secret
    parsed = JSON.parse(body)
    assert_equal "message.received", parsed["event"]
    assert_equal @server.activity_log_code, parsed["instance"]
    assert_equal "mention", parsed["match_reason"]
    assert_equal [ "body" ], parsed["history"].map { |entry| entry["message_id"] }
    refute_includes parsed["history"].to_json, @hook.secret
  end

  teardown do
    Rails.cache = @previous_cache
  end

  private

  def deliver(text:, id: "m", group: false, from_me: false, mentions_owner: false, phone: "393331111111", jid: nil)
    @hook.deliver_message!(Emcp::Servers::Whatsapp::InboundMessage.new(inbound(text:, id:, group:, from_me:, mentions_owner:, phone:, jid:)))
  end

  def inbound(text:, id: "m", group: false, from_me: false, mentions_owner: false, phone: "393331111111", skip_webhook: false, jid: nil)
    {
      "message_id" => id,
      "timestamp" => "2026-10-03T12:00:00Z",
      "chat_jid" => jid.presence || (group ? "120363@g.us" : "#{phone}@s.whatsapp.net"),
      "is_group" => group,
      "is_from_me" => from_me,
      "skip_webhook" => skip_webhook,
      "mentions_owner" => mentions_owner,
      "sender_phone" => phone,
      "type" => "text",
      "text" => text,
    }
  end
end
