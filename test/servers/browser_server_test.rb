# frozen_string_literal: true

require "test_helper"

class BrowserServerTest < ActiveSupport::TestCase
  setup do
    @server = mcp_server_for("browser")
    @previous = ENV.to_h.slice(
      "BROWSER_ALLOWED_ORIGINS",
      "BROWSER_ALLOW_EVAL",
      "BROWSER_TIMEOUT",
      "BROWSER_PAIRING_TOKEN",
      "BROWSER_PAIRED_AT",
    )
    @previous.each_key { |key| ENV.delete(key) }
    Emcp::Servers::Browser::SessionRegistry.current = Emcp::Servers::Browser::SessionRegistry.new
  end

  teardown do
    @previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Emcp::Servers::Browser::SessionRegistry.current = Emcp::Servers::Browser::SessionRegistry.new
  end

  test "catalog covers read tools and gated writes" do
    names = @server.tool_catalog.map { |tool| tool[:name] }
    %w[
      browser_status browser_list_tabs browser_get_url browser_get_text
      browser_read_table browser_screenshot browser_eval_readonly
      browser_navigate browser_click browser_type browser_download
    ].each do |name|
      assert_includes names, name
    end

    refute tool("browser_get_text")[:write]
    assert tool("browser_click")[:write]
    assert tool("browser_type")[:write]
    assert tool("browser_navigate")[:write]
  end

  test "write tools are refused unless the instance allows writes" do
    @server.update!(allow_write: false)

    error = assert_raises(SecurityError) do
      @server.call_tool("browser_click", { "selector" => "button.save" })
    end
    assert_match(/write method disabled/, error.message)
  end

  test "pairing token rotates until the extension connects, then clear revokes it" do
    assert_equal "Avvia pairing", @server.auth_submit_label
    assert @server.apply_credentials("browser_allowed_origins" => "https://edma.example.it")

    token = @server.credentials_hash["BROWSER_PAIRING_TOKEN"]
    assert_equal 64, token.length
    status = @server.fetch_auth_status
    refute status[:paired]
    refute status[:authenticated]
    assert status[:qr_png_base64].present?
    assert_includes status[:pairing_code], token

    assert @server.apply_credentials("browser_allowed_origins" => "https://edma.example.it")
    rotated = @server.credentials_hash["BROWSER_PAIRING_TOKEN"]
    refute_equal token, rotated

    @server.mark_paired!
    assert_equal "Salva", @server.auth_submit_label
    paired = @server.fetch_auth_status
    assert paired[:paired]
    assert paired[:authenticated]
    assert_nil paired[:qr_png_base64]

    assert @server.apply_credentials("browser_allowed_origins" => "https://edma.example.it")
    assert_equal rotated, @server.credentials_hash["BROWSER_PAIRING_TOKEN"]

    @server.clear_credentials!
    assert_nil @server.credentials_hash["BROWSER_PAIRING_TOKEN"]
    assert_equal "https://edma.example.it", @server.credentials_hash["BROWSER_ALLOWED_ORIGINS"]
    refute @server.fetch_auth_status[:paired]
  end

  test "blank origins allow https and a narrower list refuses other sites" do
    client = Emcp::Servers::Browser::Client.new(@server)

    assert_raises(Emcp::Servers::Browser::SessionRegistry::Offline) do
      client.call("browser_get_text", {})
    end
    error = assert_raises(RuntimeError) do
      client.call("browser_navigate", { "url" => "http://other.example/path" }, write: true)
    end
    assert_match(/allowlist/, error.message)

    @server.persist_credentials!("BROWSER_ALLOWED_ORIGINS" => "https://edma.example.it/*, https://files.example.it/*")
    error = assert_raises(RuntimeError) do
      client.call("browser_navigate", { "url" => "https://other.example/path" }, write: true)
    end
    assert_match(/allowlist/, error.message)
  end

  test "a matching origin is forwarded and a foreign result is dropped" do
    @server.persist_credentials!("BROWSER_ALLOWED_ORIGINS" => "https://edma.example.it")
    client = Emcp::Servers::Browser::Client.new(@server)
    registry = Emcp::Servers::Browser::SessionRegistry.current
    registry.define_singleton_method(:dispatch) do |_id, message, timeout:|
      url = message.dig("args", "url") || "https://edma.example.it/home"
      { "ok" => true, "result" => { "url" => url, "text" => "row" } }
    end

    result = client.call("browser_get_text", { "selector" => "table" })
    assert_equal "row", result["text"]

    registry.define_singleton_method(:dispatch) do |_id, _message, timeout:|
      { "ok" => true, "result" => { "url" => "https://other.example/secret", "text" => "hidden" } }
    end
    error = assert_raises(RuntimeError) { client.call("browser_get_text", {}) }
    assert_match(/allowlist/, error.message)
    refute_includes error.message, "hidden"
  end

  test "eval stays disabled unless BROWSER_ALLOW_EVAL is set" do
    @server.persist_credentials!("BROWSER_ALLOWED_ORIGINS" => "https://edma.example.it")
    client = Emcp::Servers::Browser::Client.new(@server)

    error = assert_raises(RuntimeError) do
      client.call("browser_eval_readonly", { "expression" => "document.title" })
    end
    assert_match(/BROWSER_ALLOW_EVAL/, error.message)

    ENV["BROWSER_ALLOW_EVAL"] = "true"
    registry = Emcp::Servers::Browser::SessionRegistry.current
    registry.define_singleton_method(:dispatch) do |_id, message, timeout:|
      raise "eval flag was not forwarded" unless message["allow_eval"]

      { "ok" => true, "result" => { "url" => "https://edma.example.it/", "value" => "\"EDMA\"" } }
    end
    assert_equal "\"EDMA\"", client.call("browser_eval_readonly", { "expression" => "document.title" })["value"]
  end

  private

  def tool(name)
    @server.tool_catalog.find { |entry| entry[:name] == name }
  end
end
