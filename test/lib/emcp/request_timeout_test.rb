# frozen_string_literal: true

require "test_helper"
require "emcp/request_timeout"

class EmcpRequestTimeoutTest < ActiveSupport::TestCase
  test "returns 504 when the app hangs past the timeout" do
    app = Emcp::RequestTimeout.new(->(_) { sleep 1; [ 200, {}, [ "ok" ] ] }, timeout: 0.05)

    status, _headers, body = app.call("PATH_INFO" => "/")

    assert_equal 504, status
    assert_equal [ "Gateway Timeout" ], body
  end

  test "does not time out liveness or readiness" do
    called = false
    app = Emcp::RequestTimeout.new(->(_) { called = true; [ 200, {}, [ "ok" ] ] }, timeout: 0.01)

    status, = app.call("PATH_INFO" => "/up")

    assert_equal 200, status
    assert called
  end
end
