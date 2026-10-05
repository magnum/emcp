# frozen_string_literal: true

require "test_helper"

class BasecampProjectLinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @server = mcp_server_for("basecamp", user: @user)
    @server.update!(credentials: { "BASECAMP_INBOUND_TOKEN" => "inbound-token" }.to_json)
  end

  test "show lists a linked project and the outbound webhook without the secret" do
    @server.basecamp_projects.create!(project_id: "2085", name: "Leto", basecamp_webhook_id: "42")
    hook = @server.basecamp_hooks.create!(url: "https://example.com/tool", secret: "supersecret")

    post sign_in_path, params: { email: @user.email, password: "password123" }
    get mcp_server_path(@server)

    assert_response :success
    assert_select "h2", text: "Projects"
    assert_select "a[href='#{mcp_server_basecamp_projects_path(@server)}']", text: "Link a project"
    assert_includes response.body, "Leto"
    refute_includes response.body, "inbound-token"
    refute_includes response.body, "supersecret"
    assert_select "a[href='#{mcp_server_edit_webhook_path(@server, hook)}']", text: "Edit"
    assert_select "a[href='#{new_mcp_server_webhook_path(@server)}']", text: "Add webhook"

    get mcp_server_edit_webhook_path(@server, hook)
    assert_response :success
    assert_select "input[name='basecamp_hook[url]'][value='https://example.com/tool']"
  end

  test "webhook form is the outbound url" do
    post sign_in_path, params: { email: @user.email, password: "password123" }
    get new_mcp_server_webhook_path(@server)

    assert_response :success
    assert_select "input[name='basecamp_hook[url]']"
    assert_select "input[name='basecamp_hook[enabled]']"
    assert_select "input[name='whatsapp_hook[url]']", count: 0
  end

  test "project index reports a CLI failure" do
    previous = ENV["BASECAMP_BIN"]
    ENV["BASECAMP_BIN"] = "/usr/bin/false"
    post sign_in_path, params: { email: @user.email, password: "password123" }
    get mcp_server_basecamp_projects_path(@server)

    assert_response :success
    assert_select "h1", text: "Projects"
    assert_match(/exited 1/, response.body)
  ensure
    if previous
      ENV["BASECAMP_BIN"] = previous
    else
      ENV.delete("BASECAMP_BIN")
    end
  end

  test "rejects a basecamp event with the wrong token" do
    post basecamp_events_mcp_server_path(@server, "nope"),
         params: { id: 1 },
         as: :json

    assert_response :unauthorized
  end

  test "accepts a basecamp event for a linked project" do
    @server.basecamp_projects.create!(project_id: "2085", name: "Leto", basecamp_webhook_id: "42")
    @server.basecamp_hooks.create!(url: "https://example.com/tool", secret: "supersecret")

    assert_enqueued_jobs 1, only: WebhookJob do
      post basecamp_events_mcp_server_path(@server, "inbound-token"),
           params: {
             id: 7,
             kind: "comment_created",
             recording: { bucket: { id: 2085 }, content: "hello" },
           },
           as: :json
    end
    assert_response :ok
  end
end
