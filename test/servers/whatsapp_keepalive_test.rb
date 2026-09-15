# frozen_string_literal: true

require "test_helper"
require Rails.root.join("servers/whatsapp/keepalive").to_s

class WhatsappKeepaliveTest < ActiveSupport::TestCase
  teardown { Emcp::Servers::Whatsapp::Keepalive.stop_for_test }

  test "can spawn next to Puma but not on the Solid Queue worker" do
    assert Emcp::Servers::Whatsapp::Keepalive.can_spawn_locally?

    ENV["SOLID_QUEUE_WORKER"] = "1"
    refute Emcp::Servers::Whatsapp::Keepalive.can_spawn_locally?

    ENV["SOLID_QUEUE_WORKER"] = "false"
    assert Emcp::Servers::Whatsapp::Keepalive.can_spawn_locally?
  ensure
    ENV.delete("SOLID_QUEUE_WORKER")
  end

  test "loop_forever keeps ticking when ping_all raises" do
    instance = Class.new(Emcp::Servers::Whatsapp::Keepalive) do
      attr_reader :calls

      def ping_all
        @calls = (@calls || 0) + 1
        raise StandardError, "boom"
      end
    end.new

    instance.loop_forever(interval: 0, iterations: 3)

    assert_equal 3, instance.calls
  end

  test "supervisor restarts a dead keepalive thread" do
    Emcp::Servers::Whatsapp::Keepalive.start_in_puma(force: true)
    assert Emcp::Servers::Whatsapp::Keepalive.alive?

    Emcp::Servers::Whatsapp::Keepalive.kill_worker_for_test
    refute Emcp::Servers::Whatsapp::Keepalive.alive?

    Emcp::Servers::Whatsapp::Keepalive.supervise(interval: 0.05, force: true)

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until Emcp::Servers::Whatsapp::Keepalive.alive? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end

    assert Emcp::Servers::Whatsapp::Keepalive.alive?
  end

  test "ping_all visits WhatsApp instances without raising when no session exists" do
    mcp_server_for("whatsapp")

    assert_nothing_raised { Emcp::Servers::Whatsapp::Keepalive.ping_all }
  end
end
