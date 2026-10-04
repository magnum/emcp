# frozen_string_literal: true

require "test_helper"

class BrowserSessionRegistryTest < ActiveSupport::TestCase
  setup do
    @registry = Emcp::Servers::Browser::SessionRegistry.new
  end

  test "a new connection replaces the previous generation" do
    first = @registry.attach(7)
    second = @registry.attach(7)

    assert @registry.connected?(7)
    @registry.detach(7, first)
    assert @registry.connected?(7)
    @registry.detach(7, second)
    refute @registry.connected?(7)
  end

  test "dispatch correlates a reply and times out without one" do
    @registry.attach(7)
    reply = @registry.dispatch(7, { "tool" => "browser_status" }, timeout: 1) do |payload|
      @registry.complete(payload["request_id"], { "ok" => true, "result" => { "connected" => true } })
    end
    assert_equal true, reply["result"]["connected"]

    assert_raises(Emcp::Servers::Browser::SessionRegistry::TimedOut) do
      @registry.dispatch(7, { "tool" => "browser_status" }, timeout: 0.3) { |_payload| }
    end
  end

  test "dispatch refuses an offline extension" do
    assert_raises(Emcp::Servers::Browser::SessionRegistry::Offline) do
      @registry.dispatch(7, { "tool" => "browser_status" }, timeout: 1)
    end
  end
end
