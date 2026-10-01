# frozen_string_literal: true

require "test_helper"
require "openssl"

class ShopifyServerTest < ActiveSupport::TestCase
  FakeClient = Struct.new(:calls, keyword_init: true) do
    def graphql(query, variables: nil)
      calls << [query, variables]
      { status: 200, body: { "data" => { "shop" => { "name" => "Cool", "myshopifyDomain" => "cool.myshopify.com" } } } }
    end
  end

  setup do
    @server = mcp_server_for("shopify")
    @server.update!(allow_write: true)
    @fake = FakeClient.new(calls: [])
    @server.instance_variable_set(:@client, @fake)
  end

  test "catalog covers store reads and graphql" do
    names = @server.tool_catalog.map { |tool| tool[:name] }
    %w[shopify_shop shopify_products shopify_orders shopify_locations shopify_graphql].each do |name|
      assert_includes names, name
    end
  end

  test "products query is sent to the admin api" do
    @server.call_tool("shopify_products", { "first" => 5, "query" => "title:shirt" })

    query, variables = @fake.calls.last
    assert_includes query, "products("
    assert_equal 5, variables[:first]
    assert_equal "title:shirt", variables[:query]
  end

  test "mutations stay disabled until allow_write is on" do
    @server.update!(allow_write: false)

    error = assert_raises(RuntimeError) do
      @server.call_tool("shopify_graphql", { "query" => "mutation { shop { name } }" })
    end
    assert_match(/write method disabled/, error.message)
  end

  test "authorize url targets the configured store" do
    with_env(
      "SHOPIFY_CLIENT_ID" => "app-id",
      "SHOPIFY_SHOP" => "cool-store",
    ) do
      @server.update!(allow_write: true)
      url = @server.oauth_call(callback_url: "https://emcp.example/callback", state: "state-1")[:authorization_url]
      assert_includes url, "https://cool-store.myshopify.com/admin/oauth/authorize"
      assert_includes url, "write_products"
    end
  end

  test "hmac accepts the shopify callback signature" do
    secret = "shpss_secret"
    params = { "code" => "abc", "shop" => "cool-store.myshopify.com", "state" => "state-1", "timestamp" => "1700000000" }
    message = params.sort.map { |key, value| "#{key}=#{value}" }.join("&")
    params["hmac"] = OpenSSL::HMAC.hexdigest("SHA256", secret, message)

    assert Emcp::Servers::Shopify::Client.valid_hmac?(params, secret: secret)
    refute Emcp::Servers::Shopify::Client.valid_hmac?(params.merge("code" => "nope"), secret: secret)
    assert Emcp::Servers::Shopify::Client.valid_hmac?(
      params.merge("id" => "12", "type_code" => "shopify", "controller" => "mcp_servers/provider_oauth"),
      secret: secret,
    )
  end

  test "shop domain rejects hosts outside myshopify.com" do
    assert_equal "cool-store.myshopify.com", Emcp::Servers::Shopify::Client.shop_domain("cool-store")
    assert_equal "escapista-store.myshopify.com",
      Emcp::Servers::Shopify::Client.shop_domain("https://admin.shopify.com/store/escapista-store/oauth/authorize")
    assert_raises(Emcp::Servers::Shopify::Client::Error) do
      Emcp::Servers::Shopify::Client.shop_domain("evil.example")
    end
  end

  private

  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
