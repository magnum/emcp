# frozen_string_literal: true

require "test_helper"

class CheckStatusJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    @user = users(:one)
    @hey = mcp_server_for("hey")
    @context = create_context!(name: "House status", servers: [ @hey ])
    clear_enqueued_jobs
    @original = Emcp::Servers::Hey::Server.instance_method(:emcp_service_info)
  end

  teardown do
    Emcp::Servers::Hey::Server.define_method(:emcp_service_info, @original) if @original
  end

  test "emails the context owner when a member fails the live check" do
    stub_hey(authenticated: false, error: "session rejected")

    assert_emails 1 do
      CheckStatusJob.perform_now(@context.id)
    end

    mail = ActionMailer::Base.deliveries.last
    assert_equal [ @user.email ], mail.to
    assert_match(/House status/, mail.subject)
    assert_match(@hey.name, mail.body.encoded)
    assert_match(@hey.activity_log_code, mail.body.encoded)
    assert_match(/session rejected/, mail.body.encoded)
    @hey.reload
    assert @hey.disconnected?
    assert_equal false, @hey.service_info["connected"]
    assert_equal "session rejected", @hey.service_info.dig("detail", "error")
  end

  test "does not email when every member is connected" do
    stub_hey(authenticated: true)

    assert_no_emails do
      CheckStatusJob.perform_now(@context.id)
    end
    assert @hey.reload.connected?
    assert_equal true, @hey.service_info["connected"]
  end

  test "does not repeat the email while the same servers stay unauthenticated" do
    stub_hey(authenticated: false, error: "session rejected")
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    assert_emails 1 do
      CheckStatusJob.perform_now(@context.id)
    end
    assert_no_emails do
      CheckStatusJob.perform_now(@context.id)
    end
  ensure
    Rails.cache = original_cache
  end

  test "schedules the next check after the interval" do
    stub_hey(authenticated: true)
    clear_enqueued_jobs

    CheckStatusJob.perform_now(@context.id)

    enqueued = enqueued_jobs.select { |job| job[:job] == CheckStatusJob }
    assert_equal 1, enqueued.size
    assert_equal [ @context.id ], enqueued.first[:args]
    assert enqueued.first[:at], "expected a delayed follow-up"
  end

  test "ensure_running enqueues one job per context" do
    clear_enqueued_jobs
    CheckStatusJob.ensure_running!(@context)
    CheckStatusJob.ensure_running!(@context)

    matches = enqueued_jobs.select { |job| job[:job] == CheckStatusJob && job[:args] == [ @context.id ] }
    assert_equal 1, matches.size
  end

  test "status interval defaults to 1800 seconds" do
    previous = ENV["EMCP_STATUS_INTERVAL"]
    ENV["EMCP_STATUS_INTERVAL"] = "1800"
    assert_equal 1800, Emcp.status_interval
    ENV["EMCP_STATUS_INTERVAL"] = "30"
    assert_equal 30, Emcp.status_interval
    ENV["EMCP_STATUS_INTERVAL"] = "nope"
    assert_equal 1800, Emcp.status_interval
  ensure
    if previous.nil?
      ENV.delete("EMCP_STATUS_INTERVAL")
    else
      ENV["EMCP_STATUS_INTERVAL"] = previous
    end
  end

  private

  def stub_hey(authenticated:, error: nil)
    payload = { authenticated: authenticated }
    payload[:error] = error if error
    Emcp::Servers::Hey::Server.define_method(:emcp_service_info) { payload }
  end
end
