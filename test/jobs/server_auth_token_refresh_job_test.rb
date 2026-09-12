# frozen_string_literal: true

require "test_helper"

class ServerAuthTokenRefreshJobTest < ActiveJob::TestCase
  setup do
    @server = mcp_server_for("twitter")
    @server.update!(service_token_refresh_in_minutes: 90)
  end

  test "does nothing and does not reschedule when service refresh is blank" do
    @server.update!(service_token_refresh_in_minutes: nil)

    assert_no_enqueued_jobs only: ServerAuthTokenRefreshJob do
      ServerAuthTokenRefreshJob.perform_now(@server)
    end
  end

  test "calls refresh_service_token! and reschedules when configured" do
    called = false
    @server.define_singleton_method(:refresh_service_token!) do
      called = true
      true
    end

    assert_enqueued_with(job: ServerAuthTokenRefreshJob, at: 90.minutes.from_now) do
      freeze_time { ServerAuthTokenRefreshJob.perform_now(@server) }
    end
    assert called
  end

  test "reschedules even when refresh returns false" do
    @server.define_singleton_method(:refresh_service_token!) { false }

    assert_enqueued_jobs 1, only: ServerAuthTokenRefreshJob do
      freeze_time { ServerAuthTokenRefreshJob.perform_now(@server) }
    end
  end

  test "EnsureServiceTokenRefreshJob refreshes enabled servers only" do
    enabled = mcp_server_for("twitter")
    enabled.update!(service_token_refresh_in_minutes: 90)
    disabled = mcp_server_for("hey")
    disabled.update!(service_token_refresh_in_minutes: nil)

    seen = []
    [ enabled, disabled ].each do |server|
      server.define_singleton_method(:refresh_service_token!) do
        seen << code
        true
      end
    end

    original = McpServer.method(:find_each)
    McpServer.define_singleton_method(:find_each) do |**_opts, &block|
      [ enabled, disabled ].each(&block)
    end

    EnsureServiceTokenRefreshJob.perform_now
    assert_equal %w[twitter], seen
  ensure
    McpServer.define_singleton_method(:find_each, original) if original
  end

  test "refresh_service_token! is public on servers that refresh credentials" do
    %w[twitter bluesky fattureincloud googleworkspace basecamp].each do |code|
      server = mcp_server_for(code)
      assert server.respond_to?(:refresh_service_token!),
        "#{code} must expose refresh_service_token! publicly for ServerAuthTokenRefreshJob"
    end
  end
end
