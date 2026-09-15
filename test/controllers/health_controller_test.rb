# frozen_string_literal: true

require "test_helper"

class HealthControllerTest < ActionDispatch::IntegrationTest
  test "up is liveness without requiring the database" do
    get "/up"

    assert_response :success
    assert_equal "ok", response.body
  end

  test "ready reports database and keepalive status" do
    get "/health/ready"

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "ok", json["status"]
    assert_includes json.keys, "whatsapp_keepalive"
  end

  test "healthz still lists registered servers" do
    get "/healthz"

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "ok", json["status"]
    assert json["servers"].is_a?(Array)
  end
end
