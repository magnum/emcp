# frozen_string_literal: true

require "test_helper"

class RemindersServerTest < ActiveSupport::TestCase
  setup do
    @server = mcp_server_for("reminders")
    @calls = []
    @responses = {
      "status" => { "lists" => 1, "default_list" => "Reminders" },
      "reminders" => { "reminders" => [], "total" => 0, "truncated" => false },
      "create" => { "id" => "https://p01-caldav.icloud.com/1/calendars/reminders/rem-1.ics", "title" => "Milk" },
    }
    @server.instance_variable_set(:@client, fake_client)
  end

  test "replace_client! builds a client without calling iCloud" do
    @server.replace_client!

    assert_instance_of Emcp::Servers::Reminders::Client, @server.instance_variable_get(:@client)
  end

  test "fetch_auth_status reports the live list count" do
    status = @server.fetch_auth_status

    assert_equal true, status[:authenticated]
    assert_equal 1, status[:lists]
    assert_equal "Reminders", status[:default_list]
    assert_equal [ "status", {} ], @calls.last
  end

  test "fetch_auth_status keeps an empty-list warning" do
    @responses["status"] = { "lists" => 0, "default_list" => nil, "warning" => "no lists" }

    status = @server.fetch_auth_status

    assert_equal true, status[:authenticated]
    assert_equal "no lists", status[:warning]
  end

  test "a failed probe is not authenticated" do
    @server.instance_variable_get(:@client).define_singleton_method(:status) { raise "iCloud rejected the Apple ID" }

    status = @server.fetch_auth_status

    assert_equal false, status[:authenticated]
    assert_equal "iCloud rejected the Apple ID", status[:error]
  end

  test "read tools pass filters through and write tools stay closed" do
    data = tool_data("reminders_get_reminders", {
      "is_completed" => false,
      "due_before" => "2026-10-19T00:00:00Z",
      "priority" => "high",
      "limit" => 0,
    })

    assert_equal 0, data["total"]
    assert_equal(
      { is_completed: false, due_before: "2026-10-19T00:00:00Z", priority: "high", limit: 0 },
      @calls.last.last,
    )
    assert_raises(SecurityError) { @server.call_tool("reminders_create", { "title" => "Milk" }) }
  end

  test "create sends title, notes, url, and priority when writes are enabled" do
    @server.update!(allow_write: true)

    data = tool_data("reminders_create", {
      "title" => "Milk",
      "notes" => "oat",
      "url" => "https://example.com/milk",
      "priority" => "high",
      "is_completed" => "false",
    })

    assert_equal "Milk", data["title"]
    assert_equal(
      {
        title: "Milk",
        notes: "oat",
        url: "https://example.com/milk",
        priority: "high",
        is_completed: false,
      },
      @calls.last.last,
    )
  end

  test "tool catalog exposes reminders tools with object output schemas" do
    names = @server.tool_catalog.map { |tool| tool[:name] }

    assert_includes names, "reminders_lists"
    assert_includes names, "reminders_next"
    assert_includes names, "reminders_delete"
    assert_includes names, "emcp_service_info"
    @server.tool_catalog.each do |tool|
      assert_equal "object", tool.dig(:output_schema, :type)
    end
  end

  private

  def fake_client
    calls = @calls
    responses = @responses
    Class.new do
      define_method(:initialize) { @calls = calls; @responses = responses }
      define_method(:status) { @calls << [ "status", {} ]; @responses.fetch("status") }
      define_method(:reminders) { |payload = {}| @calls << [ "reminders", payload ]; @responses.fetch("reminders") }
      define_method(:create_reminder) { |payload| @calls << [ "create", payload ]; @responses.fetch("create") }
    end.new
  end

  def tool_data(name, arguments = {})
    @server.call_tool(name, arguments).structured_content["data"]
  end
end
