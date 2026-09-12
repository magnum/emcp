# frozen_string_literal: true

require "test_helper"

class HeyServerTest < ActiveSupport::TestCase
  setup do
    McpServer.discover!
    @server = McpServer.fetch!("hey")
    @server.update!(allow_write: true)
  end

  test "catalog covers hey-cli v1.4.0 families" do
    names = @server.tool_catalog.map { |tool| tool[:name] }

    %w[
      hey_boxes hey_box hey_search hey_search_filters hey_threads hey_attachments
      hey_labels hey_label hey_collections hey_collection
      hey_contacts hey_contact hey_screener hey_screener_approve
      hey_drafts hey_draft hey_compose hey_reply hey_forward
      hey_move hey_bubble_up hey_calendars hey_events hey_event_day
      hey_habits hey_habit_create hey_timetrack_categories
    ].each do |name|
      assert_includes names, name
    end

    refute_includes names, "hey_threads_read"
    assert_equal "0.2.0", @server.class.version
  end

  test "search uses official refinements instead of a local box scan" do
    search = tool("hey_search")
    properties = search[:input_schema][:properties]

    assert properties.key?(:query)
    assert properties.key?(:from)
    assert properties.key?(:date)
    assert properties.key?(:inbox)
    assert properties.key?(:attachment)
    refute properties.key?(:after)
    refute properties.key?(:unseen_only)
    refute properties.key?(:deep)
    refute properties.key?(:limit)
  end

  test "tools omit --limit where hey-cli 1.4.0 rejects it" do
    %w[hey_workflow hey_screener hey_screener_history hey_search hey_contacts].each do |name|
      properties = tool(name)[:input_schema][:properties]
      refute properties.key?(:limit), "#{name} must not advertise limit"
    end

    assert tool("hey_screener_history")[:input_schema][:properties].key?(:page)
    assert tool("hey_screener_history")[:input_schema][:properties].key?(:fetch_all)
    refute tool("hey_workflow")[:input_schema][:properties].key?(:fetch_all)
  end

  test "compose and reply accept paragraphs, markdown, html, and drafts" do
    compose = tool("hey_compose")
    reply = tool("hey_reply")

    assert compose[:input_schema][:properties].key?(:paragraphs)
    assert compose[:input_schema][:properties].key?(:message_html)
    assert compose[:input_schema][:properties].key?(:draft)
    refute_includes compose[:input_schema].fetch(:required, []), "subject"
    assert_equal [ "topic_id" ], reply[:input_schema][:required]
  end

  test "compose sends joined paragraphs as Markdown" do
    payload = @server.send(
      :hey_write_payload,
      paragraphs: [ "Hi Alex,", "Tuesday **works**.", "Sam" ],
    )
    argv = @server.instance_variable_get(:@client).compose(subject: "Lunch", to: "a@b.com", **payload)

    assert_equal({ message: "Hi Alex,\n\nTuesday **works**.\n\nSam" }, payload)
    assert_includes argv, "-m"
    assert_equal "Hi Alex,\n\nTuesday **works**.\n\nSam", argv[argv.index("-m") + 1]
    refute_includes argv, "--message-html"
  end

  test "compose as_html still converts paragraphs to HEY HTML" do
    payload = @server.send(
      :hey_write_payload,
      paragraphs: [ "Hi Alex,", "- One", "- Two" ],
      as_html: true,
    )
    argv = @server.instance_variable_get(:@client).compose(subject: "Lunch", **payload)

    assert_includes argv, "--message-html"
    html = argv[argv.index("--message-html") + 1]
    assert_includes html, "<div>Hi Alex,</div>"
    assert_includes html, "<ul><li>One</li><li>Two</li></ul>"
  end

  test "format_hey_email_body still builds Trix HTML" do
    html = @server.format_hey_email_body(paragraphs: [ "Ciao Luca,", "Seconda idea.", "Antonio" ])
    assert_equal(
      "<div>Ciao Luca,</div><div><br></div><div>Seconda idea.</div><div><br></div><div>Antonio</div>",
      html,
    )
  end

  test "skill documents the official noun-first CLI" do
    text = File.read(Rails.root.join("servers/hey/skills/hey/SKILL.md"))
    assert_includes text, "hey box view"
    assert_includes text, "hey thread read"
    assert_includes text, "hey search"
    assert_includes text, "EmCP MCP tools"
    refute_includes text, "hey threads <topic_id>"
  end

  private

  def tool(name)
    @server.tool_catalog.find { |candidate| candidate[:name] == name }.tap do |definition|
      assert definition, "missing tool #{name}"
    end
  end
end
