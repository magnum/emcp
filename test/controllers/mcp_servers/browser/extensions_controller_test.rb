# frozen_string_literal: true

require "test_helper"
require "zlib"
require "stringio"

class McpServers::Browser::ExtensionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @server = mcp_server_for("browser", user: @user)
    post sign_in_path, params: { email: @user.email, password: "password123" }
  end

  test "auth page offers the extension zip and a pairing qr after submit" do
    get auth_mcp_server_path(@server)

    assert_response :success
    assert_select "a[href='#{browser_extension_mcp_server_path(@server)}']", text: "Download extension (.zip)"
    assert_select "input[type=submit][value='Avvia pairing']"
    assert_match(/Click/, response.body)

    post auth_credentials_mcp_server_path(@server), params: {
      browser_allowed_origins: "https://edma.example.it",
    }
    follow_redirect!

    assert_response :success
    assert_select "img[alt='Browser pairing QR code']"
    assert_match(/pairing payload/i, response.body)
    assert_select "input[name='browser_allowed_origins'][value='https://edma.example.it']"
  end

  test "extension zip contains the manifest and is refused for another server" do
    get browser_extension_mcp_server_path(@server)

    assert_response :success
    assert_equal "application/zip", response.media_type
    assert_includes zip_names(response.body), "manifest.json"
    assert_includes zip_names(response.body), "background.js"

    other = mcp_server_for("whatsapp", user: @user)
    get browser_extension_mcp_server_path(other)
    assert_response :not_found
  end

  private

  def zip_names(bytes)
    names = []
    io = StringIO.new(bytes)
    loop do
      header = io.read(30)
      break if header.nil? || header.bytesize < 30 || header.unpack1("V") != 0x04034b50

      _sig, _v, _flag, _method, _time, _date, _crc, comp, _uncomp, name_len, extra_len = header.unpack("VvvvvvVVVvv")
      names << io.read(name_len)
      io.read(extra_len.to_i + comp.to_i)
    end
    names
  end
end
