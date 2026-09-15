# frozen_string_literal: true

require "test_helper"
require Rails.root.join("servers/whatsapp/whatsapp_client").to_s

class WhatsappClientTest < ActiveSupport::TestCase
  setup do
    @calls = []
    @transport = lambda do |method, path, query:, body:, auth:|
      @calls << { method: method, path: path, query: query, body: body, auth: auth }
      case path
      when "/health" then { "ok" => true }
      when "/api/status" then { "connected" => true, "logged_in" => true }
      when "/api/send" then { "success" => true, "message" => "sent" }
      when "/api/chats" then [ { "jid" => "1@s.whatsapp.net", "name" => "Ada" } ]
      else {}
      end
    end
    @client = Emcp::Servers::Whatsapp::Client.new(
      base_url: "http://127.0.0.1:9",
      token: "secret",
      store_dir: Dir.mktmpdir("whatsapp-client-test"),
      transport: @transport,
    )
  end

  teardown do
    FileUtils.rm_rf(@client.instance_variable_get(:@store_dir))
  end

  test "reachable when health returns ok" do
    assert @client.reachable?
    assert_equal "/health", @calls.first[:path]
    refute @calls.first[:auth]
  end

  test "list_chats omits blank filters" do
    @client.list_chats(query: "ada", limit: 10, page: nil, sort_by: "")
    call = @calls.last
    assert_equal :get, call[:method]
    assert_equal "/api/chats", call[:path]
    assert_equal({ "query" => "ada", "limit" => 10 }, call[:query])
  end

  test "send_message posts recipient and body" do
    result = @client.send_message(recipient: "39333", message: "hello")
    call = @calls.last
    assert_equal :post, call[:method]
    assert_equal "/api/send", call[:path]
    assert_equal({ recipient: "39333", message: "hello" }, call[:body])
    assert result["success"]
  end

  test "status uses the bridge token" do
    @client.status
    assert @calls.last[:auth]
  end

  test "wait_for_pairing_code returns when the QR png is present" do
    payloads = [
      { "pairing" => true },
      { "pairing" => true, "qr_png_base64" => "abc" },
    ]
    client = Emcp::Servers::Whatsapp::Client.new(
      base_url: "http://127.0.0.1:9",
      token: "secret",
      store_dir: Dir.mktmpdir("whatsapp-wait-test"),
      transport: lambda do |method, path, query:, body:, auth:|
        case path
        when "/health" then { "ok" => true }
        when "/api/status" then payloads.shift || payloads.last || { "pairing" => true, "qr_png_base64" => "abc" }
        else {}
        end
      end,
    )

    result = client.wait_for_pairing_code!(timeout: 2)
    assert_equal "abc", result["qr_png_base64"]
  ensure
    FileUtils.rm_rf(client.instance_variable_get(:@store_dir)) if client
  end

  test "wait_for_pairing_code fails immediately when WhatsApp rejects the client" do
    client = Emcp::Servers::Whatsapp::Client.new(
      base_url: "http://127.0.0.1:9",
      token: "secret",
      store_dir: Dir.mktmpdir("whatsapp-outdated-test"),
      transport: lambda do |_method, path, query:, body:, auth:|
        case path
        when "/health" then { "ok" => true }
        when "/api/status" then { "pairing" => true, "error" => "WhatsApp rejected this companion as outdated" }
        else {}
        end
      end,
    )

    error = assert_raises(Emcp::Servers::Whatsapp::Client::Error) do
      client.wait_for_pairing_code!(timeout: 2)
    end
    assert_match(/outdated/, error.message)
  ensure
    FileUtils.rm_rf(client.instance_variable_get(:@store_dir)) if client
  end
end
