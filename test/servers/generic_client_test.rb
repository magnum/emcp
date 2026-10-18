# frozen_string_literal: true

require "test_helper"

class GenericClientTest < ActiveSupport::TestCase
  TOKEN = "secret-token"

  test "an unconfigured client does not open a session" do
    called = false
    client = Emcp::Servers::Generic::Client.new(session_factory: ->(*) { called = true })

    assert_empty client.tools
    assert_equal false, called
  end

  test "header auth sends Authorization Bearer and leaves the query empty" do
    options = capture(token_in: "header")

    assert_equal "https://wrks.it/mcp", options[:url]
    assert_equal "Bearer #{TOKEN}", options[:headers]["Authorization"]
  end

  test "a token that already includes Bearer is not wrapped again" do
    options = capture(token_in: "header", token: "Bearer #{TOKEN}")

    assert_equal "Bearer #{TOKEN}", options[:headers]["Authorization"]
  end

  test "a custom header sends the raw token" do
    options = capture(token_in: "header", token_key: "X-Api-Key")

    assert_equal TOKEN, options[:headers]["X-Api-Key"]
    assert_nil options[:headers]["Authorization"]
  end

  test "query auth appends the key and keeps an existing query" do
    options = capture(url: "https://wrks.it/mcp?tenant=a", token_in: "query", token_key: "api_key")

    assert_equal "https://wrks.it/mcp?tenant=a&api_key=#{TOKEN}", options[:url]
    assert_nil options[:headers]["Authorization"]
  end

  test "a blank query key defaults to api_key" do
    options = capture(token_in: "query", token_key: "")

    assert_includes options[:url], "api_key=#{TOKEN}"
  end

  test "session errors do not include the token" do
    client = Emcp::Servers::Generic::Client.new(
      url: "https://wrks.it/mcp",
      token: TOKEN,
      token_in: "header",
      session_factory: ->(*) { raise "rejected #{TOKEN}" },
    )

    error = assert_raises(Emcp::Servers::Generic::Client::Error) { client.status }

    assert_no_match TOKEN, error.message
    assert_match "[redacted]", error.message
  end

  private

  def capture(url: "https://wrks.it/mcp", token: TOKEN, token_in: "header", token_key: nil)
    seen = nil
    client = Emcp::Servers::Generic::Client.new(
      url: url,
      token: token,
      token_in: token_in,
      token_key: token_key,
      session_factory: lambda { |options|
        seen = options
        Session.new
      },
    )
    client.tools
    seen
  end

  class Session
    def tools = []
    def close; end
  end
end
