# frozen_string_literal: true

require "test_helper"
require Rails.root.join("servers/telegram/hook").to_s

class TelegramDispatchTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @server = mcp_server_for("telegram")
    @hook = @server.telegram_hooks.create!(
      url: "https://example.com/hook",
      secret: "supersecret",
      secret_header: "Authorization",
      enabled: true,
      debounce_minutes: 0,
    )
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "defaults stay off for delivery and skip muted chats and channels" do
    fresh = @server.telegram_hooks.create!(
      url: "https://example.com/other",
      secret: "supersecret",
      secret_header: "Authorization",
    )
    refute fresh.enabled?
    assert fresh.ignore_muted?
    assert fresh.ignore_channels?
    assert_equal "private", fresh.chat_types
    assert_equal 5, fresh.debounce_minutes

    @hook.update!(ignore_muted: true, ignore_channels: true, chat_types: "private,group,channel")
    deliver(id: "muted", muted: true)
    deliver(id: "channel", chat_type: "channel")
    assert @hook.receipts.find_by!(message_id: "muted").filtered?
    assert_equal "muted", @hook.receipts.find_by!(message_id: "muted").reason
    assert_equal "channel", @hook.receipts.find_by!(message_id: "channel").reason
  end

  test "whitelist mentions and away status decide delivery" do
    @hook.update!(chat_ids: "9")
    deliver(id: "other", chat_id: "8")
    assert_equal "chat_id", @hook.receipts.find_by!(message_id: "other").reason

    @hook.update!(chat_ids: "", chat_types: "group", mentions_only: true)
    deliver(id: "quiet", chat_type: "group", mentions_owner: false)
    deliver(id: "ping", chat_type: "group", mentions_owner: true)
    assert @hook.receipts.find_by!(message_id: "quiet").filtered?
    assert @hook.receipts.find_by!(message_id: "ping").sent?

    @hook.update!(chat_types: "private", mentions_only: false, respond_by_status: "away", owner_status: "active")
    deliver(id: "here")
    assert_equal "owner_status", @hook.receipts.find_by!(message_id: "here").reason

    @hook.update!(owner_status: "away")
    deliver(id: "gone")
    assert @hook.receipts.find_by!(message_id: "gone").sent?
  end

  test "debounce sends one event with the messages collected in the window" do
    @hook.update!(debounce_minutes: 5, chat_types: "private")

    assert_enqueued_jobs 1, only: TelegramFlushJob do
      deliver(id: "a", text: "one")
      deliver(id: "b", text: "two")
    end

    batch = Rails.cache.read(Emcp::Servers::Telegram::Aggregator.cache_key(@hook, "9"))
    assert_equal %w[a b], batch["messages"].map { |row| row["message_id"] }

    assert_enqueued_jobs 1, only: WebhookJob do
      @hook.flush!("9", batch["token"])
    end
    body = JSON.parse(@hook.receipts.find_by!(message_id: "b").webhook.body)
    assert_equal "messages.received", body["event"]
    assert_equal %w[a b], body["messages"].map { |row| row["message_id"] }
    assert_equal "active", body["owner_status"]
  end

  test "a disabled hook and messages from this account are ignored" do
    @hook.update!(enabled: false)
    @server.accept_inbound_message!(inbound(id: "off"))
    assert_empty @hook.receipts

    @hook.update!(enabled: true)
    @server.accept_inbound_message!(inbound(id: "mine", is_from_me: true))
    assert_empty @hook.receipts
  end

  private

  def deliver(id:, **extra)
    @hook.deliver_message!(Emcp::Servers::Telegram::InboundMessage.new(inbound(id: id, **extra)))
  end

  def inbound(id:, **extra)
    {
      "message_id" => id,
      "chat_id" => "9",
      "chat_title" => "Ada",
      "chat_type" => "private",
      "timestamp" => "2026-10-04T15:00:00Z",
      "text" => "ciao",
    }.merge(extra.stringify_keys)
  end
end
