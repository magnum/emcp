# frozen_string_literal: true

require "test_helper"

class JethrClientTest < ActiveSupport::TestCase
  setup do
    @server = mcp_server_for("jethr")
  end

  test "in-force list targets the company employees endpoint" do
    client = Emcp::Servers::Jethr::Client.new(@server)

    assert_equal(
      "https://backend.jethr.com/api/v1/employees/?company=112&contract_status=IN_FORCE",
      client.employees_url("112", "in_force"),
    )
    assert_equal(
      "https://backend.jethr.com/api/v1/employees/?company=112",
      client.employees_url("112", "all"),
    )
    assert_equal(
      "https://backend.jethr.com/api/v1/employees/638/",
      client.employee_url("638"),
    )
  end

  test "employees reads the admin tab and returns the reduced page" do
    steps = [
      { "tabs" => [{ "tab_id" => 5, "url" => "https://admin.jethr.com/#/112/dipendenti/tab-in-forza" }] },
      { "value" => '{"started":true}' },
      { "value" => '{"pending":false,"status":200,"body":{"total":1,"offset":0,"employees":[{"id":638,"full_name":"Ada"}]}}' },
      { "value" => '{"deleted":true}' },
    ]
    relay = lambda do |_tool, _args, timeout:|
      raise "missing timeout" unless timeout
      steps.shift || raise("unexpected call")
    end
    client = Emcp::Servers::Jethr::Client.new(@server, relay: relay)

    with_env("JETHR_COMPANY_ID" => "112") do
      page = client.employees(company_id: "112")
      assert_equal 1, page["total"]
      assert_equal 638, page.dig("employees", 0, "id")
      assert_equal "in_force", page["status"]
    end
    assert_empty steps
  end

  test "a rejected session does not include the response body" do
    steps = [
      { "tabs" => [{ "tab_id" => 5, "url" => "https://admin.jethr.com/#/112/" }] },
      { "value" => '{"started":true}' },
      { "value" => '{"pending":false,"status":403,"body":{"detail":"secret"}}' },
      { "value" => '{"deleted":true}' },
    ]
    relay = lambda do |_tool, _args, timeout:|
      steps.shift
    end
    client = Emcp::Servers::Jethr::Client.new(@server, relay: relay)

    error = assert_raises(RuntimeError) do
      client.employee(company_id: "112", employee_id: "638")
    end
    assert_match(/session expired/, error.message)
    refute_match(/secret/, error.message)
  end

  test "ids must be numeric" do
    client = Emcp::Servers::Jethr::Client.new(@server)

    assert_raises(RuntimeError) { client.employee_url("638/admin") }
    assert_raises(RuntimeError) { client.employees_url("112?x=1", "nope") }
  end

  private

  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
