# frozen_string_literal: true

require "test_helper"
require Rails.root.join("servers/whatsapp/hook").to_s
require Rails.root.join("servers/whatsapp/inbound_message").to_s
require Rails.root.join("servers/whatsapp/chat_history").to_s
require Rails.root.join("servers/whatsapp/dispatch").to_s

class WhatsappChatHistoryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_cache = Rails.cache
    @previous_limit = ENV["WHATSAPP_WEBHOOK_CHAT_HISTORY"]
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @server = mcp_server_for("whatsapp")
    @hook = @server.whatsapp_hooks.create!(url: "https://example.com/hook", secret: "supersecret")
  end

  teardown do
    Rails.cache = @previous_cache
    if @previous_limit.nil?
      ENV.delete("WHATSAPP_WEBHOOK_CHAT_HISTORY")
    else
      ENV["WHATSAPP_WEBHOOK_CHAT_HISTORY"] = @previous_limit
    end
  end

  test "keeps the newest messages per chat and includes them on the webhook" do
    ENV["WHATSAPP_WEBHOOK_CHAT_HISTORY"] = "2"
    assert_no_difference -> { Webhook.count } do
      @server.accept_inbound_message!(inbound_attrs("old", "2026-10-03T12:00:00Z", "one", group: true))
      @server.accept_inbound_message!(inbound_attrs("mid", "2026-10-03T12:01:00Z", "two", group: true))
    end
    assert_difference -> { Webhook.count }, 1 do
      @server.accept_inbound_message!(inbound_attrs("new", "2026-10-03T12:02:00Z", "embot", group: true, mentions_owner: true))
    end

    history = Emcp::Servers::Whatsapp::ChatHistory.for(@server.id, "120363@g.us")
    assert_equal %w[mid new], history.map { |entry| entry["message_id"] }

    body = JSON.parse(@hook.receipts.find_by!(message_id: "new").webhook.body)
    assert_equal "embot", body["text"]
    assert_equal %w[mid new], body["history"].map { |entry| entry["message_id"] }
    assert_equal "two", body["history"].first["text"]
  end

  test "a repeated message id replaces the cached copy" do
    @server.accept_inbound_message!(inbound_attrs("same", "2026-10-03T12:00:00Z", "first"))
    Emcp::Servers::Whatsapp::ChatHistory.record!(@server.id, inbound("same", "2026-10-03T12:00:00Z", "edited"))

    history = Emcp::Servers::Whatsapp::ChatHistory.for(@server.id, "393331111111@s.whatsapp.net")
    assert_equal [ "same" ], history.map { |entry| entry["message_id"] }
    assert_equal "edited", history.first["text"]
  end

  test "chats do not share a window" do
    @server.accept_inbound_message!(inbound_attrs("dm", "2026-10-03T12:00:00Z", "ciao"))
    @server.accept_inbound_message!(inbound_attrs("grp", "2026-10-03T12:00:00Z", "gruppo", group: true))

    direct = Emcp::Servers::Whatsapp::ChatHistory.for(@server.id, "393331111111@s.whatsapp.net")
    group = Emcp::Servers::Whatsapp::ChatHistory.for(@server.id, "120363@g.us")
    assert_equal [ "dm" ], direct.map { |entry| entry["message_id"] }
    assert_equal [ "grp" ], group.map { |entry| entry["message_id"] }
  end

  private

  def inbound_attrs(id, timestamp, text, group: false, mentions_owner: false)
    inbound(id, timestamp, text, group:, mentions_owner:).attributes
  end

  def inbound(id, timestamp, text, group: false, mentions_owner: false)
    Emcp::Servers::Whatsapp::InboundMessage.new(
      "message_id" => id,
      "timestamp" => timestamp,
      "chat_jid" => (group ? "120363@g.us" : "393331111111@s.whatsapp.net"),
      "is_group" => group,
      "mentions_owner" => mentions_owner,
      "sender_phone" => "393331111111",
      "type" => "text",
      "text" => text,
    )
  end
end
