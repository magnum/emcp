# frozen_string_literal: true

require "test_helper"

class McpActivityLogTest < ActiveSupport::TestCase
  setup do
    McpActivityLog.reset!
    FileUtils.rm_rf(McpActivityLog.directory)
  end

  teardown do
    McpActivityLog.reset!
    FileUtils.rm_rf(McpActivityLog.directory)
    Current.reset
  end

  test "retain_days defaults to 30" do
    assert_equal 30, Settings.logs.retain_days
    assert_equal 30, McpActivityLog.retain_days
  end

  test "record writes a standard line with required fields" do
    McpActivityLog.record(
      server: "onepassword",
      tool: "onepassword_item_get",
      status: "ok",
      command: "op item get github --vault prod",
      ip: "203.0.113.9",
      user: "user1@emcp.local",
    )
    McpActivityLog.reset!

    line = File.readlines(McpActivityLog.path_for("onepassword")).last
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, line)
    assert_match(/ INFO onepassword /, line)
    assert_includes line, "ip=203.0.113.9"
    assert_includes line, "server=onepassword"
    assert_includes line, "user=user1@emcp.local"
    assert_includes line, "tool=onepassword_item_get"
    assert_includes line, "status=ok"
    assert_includes line, "command=\"op item get github --vault prod\""
  end

  test "redacts sensitive argument keys in fallback command" do
    command = McpActivityLog.command_from_arguments(
      "onepassword_auth",
      { token: "ops_secret", vault: "prod" },
    )
    assert_includes command, "token=[REDACTED]"
    assert_includes command, "vault=prod"
    refute_includes command, "ops_secret"
  end

  test "purge_expired deletes dated logs older than retain_days" do
    dir = McpActivityLog.directory
    FileUtils.mkdir_p(dir)
    old = dir.join("onepassword.log.20200101")
    recent = dir.join("onepassword.log.#{Date.current.strftime("%Y%m%d")}")
    File.write(old, "old\n")
    File.write(recent, "recent\n")

    McpActivityLog.purge_expired

    refute_path_exists old
    assert_path_exists recent
  end
end
