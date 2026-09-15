# frozen_string_literal: true

require "test_helper"
require Rails.root.join("servers/whatsapp/keepalive").to_s

class WhatsappBridgeKeepaliveJobTest < ActiveJob::TestCase
  test "can spawn next to Puma but not on the Solid Queue worker" do
    assert Emcp::Servers::Whatsapp::Keepalive.can_spawn_locally?

    ENV["SOLID_QUEUE_WORKER"] = "1"
    refute Emcp::Servers::Whatsapp::Keepalive.can_spawn_locally?
  ensure
    ENV.delete("SOLID_QUEUE_WORKER")
  end

  test "perform is a no-op on the worker" do
    ENV["SOLID_QUEUE_WORKER"] = "1"
    assert_nothing_raised { WhatsappBridgeKeepaliveJob.perform_now }
  ensure
    ENV.delete("SOLID_QUEUE_WORKER")
  end

  test "ping_all visits WhatsApp instances without raising when no session exists" do
    mcp_server_for("whatsapp")

    assert_nothing_raised { Emcp::Servers::Whatsapp::Keepalive.ping_all }
  end
end
