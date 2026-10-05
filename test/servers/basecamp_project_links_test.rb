# frozen_string_literal: true

require "test_helper"

class BasecampProjectLinksTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  setup do
    @server = mcp_server_for("basecamp")
  end

  test "linking a project registers the emcp url and stores the webhook id" do
    calls = with_cli([
      { "ok" => true, "data" => { "id" => 42, "payload_url" => "https://example.test/hook" } }.to_json,
    ])

    project = @server.link_basecamp_project!(project_id: "2085", name: "Leto")

    assert_equal "2085", project.project_id
    assert_equal "42", project.basecamp_webhook_id
    args = calls.sole
    assert_equal "webhooks", args[0]
    assert_equal "create", args[1]
    assert_includes args[2], "/servers/#{@server.id}/basecamp_events/"
    assert_equal [ "--types", "Comment,Message", "--in", "2085", "--json" ], args[3..]
    token = args[2].split("/").last
    assert @server.inbound_token_match?(token)
    refute_equal token, @server.credentials_hash["BASECAMP_TOKEN"]
  end

  test "linking the same project does not create a second webhook" do
    @server.basecamp_projects.create!(project_id: "2085", name: "Leto", basecamp_webhook_id: "9")
    calls = with_cli([])

    project = @server.link_basecamp_project!(project_id: "2085", name: "Leto")

    assert_equal "9", project.basecamp_webhook_id
    assert_empty calls
  end

  test "remote project list keeps active projects" do
    with_cli([
      {
        "ok" => true,
        "data" => [
          { "id" => 1, "name" => "Leto", "status" => "active" },
          { "id" => 2, "name" => "Old", "status" => "archived" },
          { "id" => 3, "name" => "Next" },
        ],
      }.to_json,
    ])

    assert_equal [
      { "id" => "1", "name" => "Leto" },
      { "id" => "3", "name" => "Next" },
    ], @server.remote_projects
  end

  test "unlinking deletes the basecamp webhook" do
    project = @server.basecamp_projects.create!(project_id: "2085", name: "Leto", basecamp_webhook_id: "42")
    calls = with_cli([ { "ok" => true, "data" => {} }.to_json ])
    server = @server
    project.define_singleton_method(:mcp_server) { server }

    project.unlink!

    assert_equal [ "webhooks", "delete", "42", "--in", "2085", "--json" ], calls.sole
    assert_not Emcp::Servers::Basecamp::Project.exists?(project.id)
  end

  test "a comment on a linked project is forwarded once" do
    @server.basecamp_projects.create!(project_id: "2085", name: "Leto", basecamp_webhook_id: "42")
    hook = @server.basecamp_hooks.create!(url: "https://example.com/tool", secret: "supersecret")
    event = {
      "id" => 9001,
      "kind" => "comment_created",
      "recording" => {
        "content" => '<bc-attachment sgid="BAh7">Victor</bc-attachment>',
        "bucket" => { "id" => 2085 },
      },
    }

    assert_enqueued_jobs 1, only: WebhookJob do
      @server.accept_basecamp_event!(JSON.generate(event))
    end
    assert_enqueued_jobs 0, only: WebhookJob do
      @server.accept_basecamp_event!(JSON.generate(event))
    end

    body = JSON.parse(hook.webhooks.sole.body)
    assert_equal "basecamp.event", body["event"]
    assert_equal "2085", body["project_id"]
    assert_equal "comment_created", body["kind"]
    assert_includes body.dig("basecamp", "recording", "content"), "bc-attachment"
    assert_equal 1, hook.receipts.count
  end

  test "an event for an unlinked project is ignored" do
    @server.basecamp_hooks.create!(url: "https://example.com/tool", secret: "supersecret")

    assert_no_enqueued_jobs only: WebhookJob do
      @server.accept_basecamp_event!(JSON.generate(
        "id" => 1,
        "kind" => "comment_created",
        "recording" => { "bucket" => { "id" => 999 } },
      ))
    end
  end

  private

  def with_cli(responses)
    calls = []
    fake = Object.new
    fake.define_singleton_method(:run) do |args, truncate: true|
      calls << args
      raw = responses.shift
      raise "unexpected CLI call #{args.inspect}" if raw.nil?

      raw
    end
    @server.define_singleton_method(:replace_client!) { @client = fake }
    calls
  end
end
