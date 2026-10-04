# frozen_string_literal: true

require "test_helper"
require Rails.root.join("servers/telegram/telegram_client").to_s

class TelegramClientTest < ActiveSupport::TestCase
  setup do
    @calls = []
    @sleeps = []
    @attempts = 0
    @client = Emcp::Servers::Telegram::Client.new(
      base_url: "http://127.0.0.1:9",
      token: "secret",
      store_dir: Dir.mktmpdir("telegram-client-test"),
      sleeper: ->(seconds) { @sleeps << seconds },
      transport: lambda do |method, path, query:, body:, auth:|
        @calls << { method: method, path: path, query: query, body: body, auth: auth }
        @script&.call || { status: 200, body: {} }
      end,
    )
  end

  teardown do
    FileUtils.rm_rf(@client.instance_variable_get(:@store_dir))
  end

  test "list_messages stamps unix timestamps as RFC3339 UTC" do
    @script = lambda do
      { status: 200, body: { "messages" => [ { "message_id" => "1", "timestamp" => "1728000000" } ] } }
    end

    result = @client.list_messages(chat_id: "42")

    assert_equal "/api/messages", @calls.last[:path]
    assert_equal "2024-10-04T00:00:00Z", result["messages"].first["timestamp"]
    refute @calls.any? { |call| call[:path].match?(/read/i) }
  end

  test "flood wait retries then returns the successful body" do
    @script = lambda do
      @attempts += 1
      if @attempts < 3
        { status: 429, body: { "error" => "FLOOD_WAIT_2", "flood_wait_seconds" => 2 } }
      else
        { status: 200, body: { "chats" => [] } }
      end
    end

    result = @client.list_unread

    assert_equal [ 2, 2 ], @sleeps
    assert_equal [], result["chats"]
  end

  test "a long flood wait is returned with Telegram's message" do
    @script = lambda do
      { status: 429, body: { "error" => "FLOOD_WAIT_120", "flood_wait_seconds" => 120 } }
    end

    error = assert_raises(Emcp::Servers::Telegram::Client::Error) { @client.list_chats }
    assert_equal "Telegram FloodWait: retry after 120 seconds. FLOOD_WAIT_120", error.message
    assert_empty @sleeps
  end

  test "the bridge source never marks messages read" do
    source = Dir[Rails.root.join("servers/telegram/bridge/*.go")].map { |path| File.read(path) }.join
    refute_match(/ReadHistory|ReadMessageContents/, source)
  end
end
