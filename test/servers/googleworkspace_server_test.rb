# frozen_string_literal: true

require "test_helper"

class GoogleWorkspaceServerTest < ActiveSupport::TestCase
  setup do
    @server = mcp_server_for("googleworkspace")
  end

  teardown do
    FileUtils.rm_rf(@server.data_dir) if @server
  end

  test "data_dir and gws config dir are owner-only" do
    assert_equal 0o700, File.stat(@server.data_dir).mode & 0o777
    assert_equal 0o700, File.stat(@server.send(:gws_config_dir)).mode & 0o777
  end

  test "materialize writes 0600 credential files from the encrypted blob" do
    credentials = {
      "type" => "authorized_user",
      "client_id" => "cid.apps.googleusercontent.com",
      "client_secret" => "csecret",
      "refresh_token" => "refresh-token",
      "project_id" => "proj-1",
    }
    @server.send(:persist_workspace_blob!, credentials)
    @server.send(:materialize_workspace_credentials!)

    path = @server.send(:credentials_path)
    secret = File.join(@server.send(:gws_config_dir), "client_secret.json")
    assert File.file?(path)
    assert File.file?(secret)
    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_equal 0o600, File.stat(secret).mode & 0o777
    stored = JSON.parse(File.read(path))
    assert_equal "refresh-token", stored["refresh_token"]
    assert_equal path, ENV["GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"]
    assert_equal @server.send(:gws_config_dir), ENV["GOOGLE_WORKSPACE_CLI_CONFIG_DIR"]
    refute_includes File.read(@server.instance_settings_path), "refresh-token" if File.file?(@server.instance_settings_path)
  end

  test "imports a leftover plaintext credentials.json into the encrypted column" do
    leftover = File.join(@server.data_dir, "credentials.json")
    File.write(
      leftover,
      JSON.pretty_generate(
        "type" => "authorized_user",
        "client_id" => "cid.apps.googleusercontent.com",
        "client_secret" => "csecret",
        "refresh_token" => "legacy-refresh",
      ),
      perm: 0o777,
    )

    @server.load_credentials!

    blob = @server.send(:workspace_credentials_blob)
    assert_equal "legacy-refresh", blob["refresh_token"]
    refute File.file?(leftover)
    assert_equal 0o600, File.stat(@server.send(:credentials_path)).mode & 0o777
  end

  test "refresh_service_token! updates the encrypted blob" do
    @server.send(:persist_workspace_blob!, {
      "type" => "authorized_user",
      "client_id" => "cid.apps.googleusercontent.com",
      "client_secret" => "csecret",
      "refresh_token" => "refresh-token",
    })

    response = Net::HTTPSuccess.new("1.1", "200", "OK")
    def response.body
      { "access_token" => "new-access", "expires_in" => 3600, "refresh_token" => "new-refresh" }.to_json
    end
    original = Net::HTTP.method(:post_form)
    Net::HTTP.define_singleton_method(:post_form) { |*_args| response }
    assert @server.refresh_service_token!
  ensure
    Net::HTTP.define_singleton_method(:post_form, original) if original

    blob = @server.send(:workspace_credentials_blob)
    assert_equal "new-access", blob["access_token"]
    assert_equal "new-refresh", blob["refresh_token"]
    assert_equal "new-refresh", JSON.parse(File.read(@server.send(:credentials_path)))["refresh_token"]
  end
end
