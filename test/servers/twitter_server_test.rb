# frozen_string_literal: true

require "test_helper"
require "base64"

class TwitterServerTest < ActiveSupport::TestCase
  FakeClient = Struct.new(:calls, :routes, keyword_init: true) do
    def initialize(calls: [], routes: Hash.new { |queue, key| queue[key] = [] })
      super
    end

    def stub(method, path, response)
      routes[[method, path]] << response
    end

    def post(path, body: nil, query: {}, raise_on_error: true, api_base: nil)
      calls << { method: :post, path: path, body: body, query: query, api_base: api_base }
      shift(:post, path)
    end

    def get(path, query: {}, raise_on_error: true, api_base: nil)
      calls << { method: :get, path: path, query: query, api_base: api_base }
      shift(:get, path)
    end

    private

    def shift(method, path)
      queue = routes[[method, path]]
      raise "unexpected #{method} #{path}" if queue.empty?

      queue.shift
    end
  end

  setup do
    @server = mcp_server_for("twitter")
    @server.update!(allow_write: true)
    @fake = FakeClient.new
    @server.instance_variable_set(:@client, @fake)
  end

  test "simple image upload posts media and alt text metadata" do
    bytes = "png-bytes"
    @fake.stub(:post, "media/upload", {
      status: 200,
      body: {
        "data" => {
          "id" => "1880028106020515840",
          "media_key" => "3_1880028106020515840",
          "size" => bytes.bytesize,
          "expires_after_secs" => 86_400,
        },
      },
    })
    @fake.stub(:post, "media/metadata", { status: 200, body: { "data" => { "id" => "1880028106020515840" } } })

    result = @server.call_tool("twitter_media_upload", {
      "data_base64" => Base64.strict_encode64(bytes),
      "mime_type" => "image/png",
      "alt_text" => "A hill",
    })

    data = result.structured_content.fetch("data")
    assert_equal "1880028106020515840", data["media_id"]
    assert_equal "3_1880028106020515840", data["media_key"]
    assert_equal "tweet_image", data["type"]
    assert_equal bytes.bytesize, data["size"]
    assert_equal 86_400, data["expires_after_secs"]

    upload = @fake.calls[0]
    assert_equal :post, upload[:method]
    assert_equal "media/upload", upload[:path]
    assert_equal Emcp::Servers::Twitter::Client::MEDIA_BASE, upload[:api_base]
    assert_equal "tweet_image", upload[:body]["media_category"]
    assert_equal Base64.strict_encode64(bytes), upload[:body]["media"]

    metadata = @fake.calls[1]
    assert_equal "media/metadata", metadata[:path]
    assert_equal "1880028106020515840", metadata[:body]["id"]
    assert_equal "A hill", metadata[:body].dig("metadata", "alt_text", "text")
  end

  test "chunked video upload initializes appends finalizes and polls status" do
    bytes = "video-bytes"
    media_id = "1880028106020515841"
    @fake.stub(:post, "media/upload/initialize", {
      status: 200,
      body: {
        "data" => {
          "id" => media_id,
          "media_key" => "13_#{media_id}",
          "expires_after_secs" => 86_400,
        },
      },
    })
    @fake.stub(:post, "media/upload/#{media_id}/append", { status: 200, body: { "data" => { "id" => media_id } } })
    @fake.stub(:post, "media/upload/#{media_id}/finalize", {
      status: 200,
      body: {
        "data" => {
          "id" => media_id,
          "media_key" => "13_#{media_id}",
          "processing_info" => { "state" => "pending", "check_after_secs" => 0 },
        },
      },
    })
    @fake.stub(:get, "media/upload", {
      status: 200,
      body: {
        "data" => {
          "id" => media_id,
          "media_key" => "13_#{media_id}",
          "size" => bytes.bytesize,
          "expires_after_secs" => 86_400,
          "processing_info" => { "state" => "succeeded" },
        },
      },
    })

    result = @server.call_tool("twitter_media_upload", {
      "data_base64" => Base64.strict_encode64(bytes),
      "mime_type" => "video/mp4",
    })

    data = result.structured_content.fetch("data")
    assert_equal media_id, data["media_id"]
    assert_equal "13_#{media_id}", data["media_key"]
    assert_equal "tweet_video", data["type"]
    assert_equal bytes.bytesize, data["size"]
    assert_equal 86_400, data["expires_after_secs"]

    assert_equal [
      "media/upload/initialize",
      "media/upload/#{media_id}/append",
      "media/upload/#{media_id}/finalize",
    ], @fake.calls.select { |call| call[:method] == :post }.map { |call| call[:path] }
    init = @fake.calls[0]
    assert_equal Emcp::Servers::Twitter::Client::MEDIA_BASE, init[:api_base]
    assert_equal({ "media_type" => "video/mp4", "total_bytes" => bytes.bytesize, "media_category" => "tweet_video" }, init[:body])
    append = @fake.calls[1]
    assert_equal 0, append[:body]["segment_index"]
    assert_equal Base64.strict_encode64(bytes), append[:body]["media"]
    assert_nil @fake.calls[2][:body]

    status = @fake.calls[3]
    assert_equal :get, status[:method]
    assert_equal({ "command" => "STATUS", "media_id" => media_id }, status[:query])
  end

  test "tweet create maps media_ids and keeps the raw payload" do
    @fake.stub(:post, "/tweets", { status: 201, body: { "data" => { "id" => "1880028106020515999" } } })

    @server.call_tool("twitter_tweet_create", {
      "text" => "Closer crop",
      "media_ids" => %w[1880028106020515840 1880028106020515841],
      "payload" => { "reply" => { "in_reply_to_tweet_id" => "1880028106020515000" } },
    })

    body = @fake.calls.last[:body]
    assert_equal "Closer crop", body["text"]
    assert_equal %w[1880028106020515840 1880028106020515841], body.dig("media", "media_ids")
    assert_equal "1880028106020515000", body.dig("reply", "in_reply_to_tweet_id")
    assert_nil @fake.calls.last[:api_base]
  end

  test "missing media.write scope surfaces the X error and asks for re-authorization" do
    detail = "Your client application is not permitted the media.write scope"
    @fake.stub(:post, "media/upload", {
      status: 403,
      body: { "title" => "Forbidden", "detail" => detail, "status" => 403 },
    })

    result = @server.call_tool("twitter_media_upload", {
      "data_base64" => Base64.strict_encode64("png-bytes"),
      "mime_type" => "image/png",
    })

    text = result.structured_content.fetch("text")
    assert_includes text, detail
    assert_includes text, "Re-authorize"
    assert_match(/media\.write/, text)
  end

  test "unsupported format and oversized images are rejected before upload" do
    format = @server.call_tool("twitter_media_upload", {
      "data_base64" => Base64.strict_encode64("bmp"),
      "mime_type" => "image/bmp",
    })
    assert_includes format.structured_content.fetch("text"), "unsupported media format"
    assert_empty @fake.calls

    too_big = "x" * (Emcp::Servers::Twitter::MediaUpload::IMAGE_LIMIT + 1)
    oversized = @server.call_tool("twitter_media_upload", {
      "data_base64" => Base64.strict_encode64(too_big),
      "mime_type" => "image/jpeg",
    })
    assert_includes oversized.structured_content.fetch("text"), "file too large"
    assert_empty @fake.calls
  end

  test "rate limit includes the X message" do
    @fake.stub(:post, "media/upload", {
      status: 429,
      headers: { "retry-after" => "30" },
      body: { "title" => "Too Many Requests", "detail" => "Rate limit exceeded" },
    })

    result = @server.call_tool("twitter_media_upload", {
      "data_base64" => Base64.strict_encode64("png-bytes"),
      "mime_type" => "image/png",
    })

    text = result.structured_content.fetch("text")
    assert_includes text, "rate limit"
    assert_includes text, "Rate limit exceeded"
    assert_includes text, "retry-after=30"
  end

  test "authorization requests only the configured scopes" do
    with_env(
      "TWITTER_CLIENT_ID" => "client-id",
      "TWITTER_CLIENT_SECRET" => "client-secret",
      "TWITTER_OAUTH_SCOPES" => "tweet.read tweet.write offline.access",
    ) do
      url = @server.oauth_call(callback_url: "https://emcp.example/callback", state: "state-1")[:authorization_url]
      scope = URI.decode_www_form(URI.parse(url).query).to_h.fetch("scope").split
      assert_equal %w[tweet.read tweet.write offline.access], scope
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
