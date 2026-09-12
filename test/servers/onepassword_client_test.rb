# frozen_string_literal: true

require "test_helper"
require Rails.root.join("servers/onepassword/onepassword_client").to_s

class OnePasswordClientTest < ActiveSupport::TestCase
  setup do
    @client = Emcp::Servers::OnePassword::Client.new
  end

  test "whoami and vault commands use json format" do
    assert_equal %w[user get --me --format=json], @client.whoami
    assert_equal %w[vault list --format=json], @client.vault_list
    assert_equal %w[vault get abc --format=json], @client.vault_get("abc")
    assert_equal %w[service-account ratelimit --format=json], @client.ratelimit
  end

  test "item list accepts vault categories tags and archive" do
    assert_equal %w[item list --format=json], @client.item_list
    assert_equal(
      %w[item list --vault prod --categories LOGIN --tags api --include-archive --format=json],
      @client.item_list(vault: "prod", categories: "LOGIN", tags: "api", include_archive: true),
    )
  end

  test "item get reveals fields and prefers vault" do
    assert_equal(
      %w[item get github --vault prod --fields label=password --reveal --format=json],
      @client.item_get("github", vault: "prod", fields: "label=password"),
    )
  end

  test "item create and edit pass assignments" do
    assert_equal(
      %w[item create --title API --category LOGIN --vault prod --generate-password username=ada --format=json],
      @client.item_create(
        title: "API",
        category: "LOGIN",
        vault: "prod",
        assignments: ["username=ada"],
        generate_password: true,
      ),
    )
    assert_equal(
      %w[item edit item-id --vault prod password=secret --format=json],
      @client.item_edit("item-id", vault: "prod", assignments: ["password=secret"]),
    )
  end

  test "read uses the secret reference without json wrapping" do
    assert_equal ["read", "op://prod/github/password"], @client.read_reference("op://prod/github/password")
  end

  test "document get writes to stdout" do
    assert_equal(
      %w[document get license --vault prod --output=-],
      @client.document_get("license", vault: "prod"),
    )
  end

  test "config dir is forced to mode 700" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config")
      FileUtils.mkdir_p(path)
      File.chmod(0o755, path)
      ENV["OP_CONFIG_DIR"] = path

      assert_equal path, Emcp::Servers::OnePassword::Client.new.send(:config_dir)
      assert_equal 0o700, File.stat(path).mode & 0o777
    end
  ensure
    ENV.delete("OP_CONFIG_DIR")
  end

  test "errors redact the service account token" do
    ENV["OP_SERVICE_ACCOUNT_TOKEN"] = "ops_super_secret_token"
    message = @client.send(:redact, "op exited 1: invalid token ops_super_secret_token")
    assert_includes message, "[REDACTED]"
    refute_includes message, "ops_super_secret_token"
  ensure
    ENV.delete("OP_SERVICE_ACCOUNT_TOKEN")
  end
end
