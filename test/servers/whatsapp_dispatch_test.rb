# frozen_string_literal: true

require "test_helper"
require Rails.root.join("servers/whatsapp/hook").to_s
require Rails.root.join("servers/whatsapp/inbound_message").to_s
require Rails.root.join("servers/whatsapp/dispatch").to_s

class WhatsappDispatchTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  setup do
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
    assert_equal "not_considered", @hook.receipts.find_by(message_id: "g1").reason
  end

  test "group mentions and trigger words send" do
    deliver(text: "hey", group: true, mentions_owner: true, id: "m1")
    assert_equal "mention", @hook.receipts.find_by!(message_id: "m1").reason

    @hook.update!(consider_mentions: false)
    deliver(text: "please EMBOT help", group: true, mentions_owner: false, id: "w1")
    receipt = @hook.receipts.find_by!(message_id: "w1")
    assert receipt.sent?
    assert_equal "words", receipt.reason
    assert_includes JSON.parse(receipt.webhook.body)["matched_words"], "embot"
  end

  test "whole words only" do
    deliver(text: "embotting", group: true, mentions_owner: false, id: "part")
    assert @hook.receipts.find_by!(message_id: "part").filtered?
  end

  test "messages from me are ignored unless they contain a trigger word" do
    deliver(text: "ciao", group: false, from_me: true, id: "me1")
    assert_equal "from_me", @hook.receipts.find_by!(message_id: "me1").reason
    assert_no_enqueued_jobs only: WebhookJob

    deliver(text: "embot", group: false, from_me: true, id: "me2")
    assert @hook.receipts.find_by!(message_id: "me2").sent?
  end

  test "all messages still ignores is_from_me" do
    @hook.update!(consider_all_messages: true)
    deliver(text: "ciao", group: true, from_me: true, id: "all-me")
    assert_equal "from_me", @hook.receipts.find_by!(message_id: "all-me").reason

    deliver(text: "ciao", group: true, mentions_owner: false, id: "all")
    assert_equal "all", @hook.receipts.find_by!(message_id: "all").reason
  end

  test "number filters and filtered_out wins" do
    @hook.update!(respond_numbers_filtered_in: "+39 111", respond_numbers_filtered_out: "39111")
    deliver(text: "ciao", phone: "39111", id: "both")
    assert_equal "filtered_out", @hook.receipts.find_by!(message_id: "both").reason

    @hook.receipts.delete_all
    @hook.update!(respond_numbers_filtered_out: "")
    deliver(text: "ciao", phone: "39 111", id: "in")
    assert @hook.receipts.find_by!(message_id: "in").sent?

    deliver(text: "ciao", phone: "39222", id: "out")
    assert_equal "filtered_in", @hook.receipts.find_by!(message_id: "out").reason
  end

  test "respond_by_status follows owner_status" do
    @hook.update!(owner_status: "away", respond_by_status: "active")
    deliver(text: "ciao", id: "away-active")
    assert_equal "owner_status", @hook.receipts.find_by!(message_id: "away-active").reason

    @hook.update!(respond_by_status: "away")
    deliver(text: "ciao", id: "away-away")
    assert @hook.receipts.find_by!(message_id: "away-away").sent?

    @hook.update!(owner_status: "active", respond_by_status: "every")
    deliver(text: "ciao", id: "every")
    assert @hook.receipts.find_by!(message_id: "every").sent?
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
    assert_equal [ "embot" ], parsed["matched_words"]
  end

  private

  def deliver(text:, id: "m", group: false, from_me: false, mentions_owner: false, phone: "393331111111")
    message = Emcp::Servers::Whatsapp::InboundMessage.new(
      "message_id" => id,
      "timestamp" => "2026-10-03T12:00:00Z",
      "chat_jid" => (group ? "120363@g.us" : "#{phone}@s.whatsapp.net"),
      "is_group" => group,
      "is_from_me" => from_me,
      "mentions_owner" => mentions_owner,
      "sender_phone" => phone,
      "type" => "text",
      "text" => text,
    )
    @hook.deliver_message!(message)
  end
end
