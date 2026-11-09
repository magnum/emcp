# frozen_string_literal: true

require "test_helper"

class JethrServerTest < ActiveSupport::TestCase
  FakeClient = Struct.new(:calls, keyword_init: true) do
    def probe(company_id:)
      calls << [:probe, company_id]
      { company_id: company_id, email: "ada@example.com" }
    end

    def employees(company_id:, status:, offset:, limit:)
      calls << [:employees, company_id, status, offset, limit]
      { "company_id" => company_id, "status" => status, "employees" => [{ "id" => 638 }] }
    end

    def employee(company_id:, employee_id:)
      calls << [:employee, company_id, employee_id]
      { "id" => employee_id, "company_id" => company_id }
    end

    def payrolls(company_id:, offset:, limit:)
      calls << [:payrolls, company_id, offset, limit]
      { "company_id" => company_id, "payrolls" => [] }
    end

    def payroll(company_id:, period:, year:, month:, limit:)
      calls << [:payroll, company_id, period, year, month, limit]
      { "company_id" => company_id, "month" => 9, "year" => 2026 }
    end

    def report(company_id:, section:, year:, month:)
      calls << [:report, company_id, section, year, month]
      { "company_id" => company_id, "section" => section }
    end
  end

  setup do
    @server = mcp_server_for("jethr")
    @fake = FakeClient.new(calls: [])
    @server.instance_variable_set(:@client, @fake)
  end

  test "catalog lists employees and one employee" do
    names = @server.tool_catalog.map { |tool| tool[:name] }
    assert_includes names, "jethr_employees"
    assert_includes names, "jethr_employee"
    assert_includes names, "jethr_payrolls"
    assert_includes names, "jethr_payroll"
    assert_includes names, "jethr_report"
  end

  test "saving credentials signs in through the public session method" do
    client = @fake
    @server.define_singleton_method(:replace_client!) { @client = client }
    client.define_singleton_method(:ensure_session!) { calls << [ :ensure_session ] }
    client.define_singleton_method(:mfa_challenge?) { false }
    @server.persist_credentials!(
      "JETHR_EMAIL" => "ada@example.com",
      "JETHR_PASSWORD" => "secret",
      "JETHR_COMPANY_ID" => "112",
      "JETHR_MFA_PENDING" => nil,
    )

    @server.apply_credentials(
      "jethr_email" => "ada@example.com",
      "jethr_password" => "secret",
      "jethr_company_id" => "112",
    )

    assert_includes @fake.calls, [ :ensure_session ]
  end

  test "auth asks for the security code while the second factor is pending" do
    assert_includes @server.auth_fields.map { |field| field[:name] }, "jethr_otp"

    @server.persist_credentials!(
      "JETHR_COMPANY_ID" => "112",
      "JETHR_EMAIL" => "ada@example.com",
      "JETHR_MFA_PENDING" => "true",
    )

    status = @server.fetch_auth_status
    assert_equal false, status[:authenticated]
    assert_equal true, status[:mfa_required]
    assert_match(/codice di 6 caratteri/i, status[:error])
  end

  test "employees uses the configured company and the in-force filter" do
    with_env("JETHR_COMPANY_ID" => "112") do
      @server.call_tool("jethr_employees", {})
    end

    assert_equal [:employees, "112", nil, 0, nil], @fake.calls.last
  end

  test "employee detail passes the id" do
    with_env("JETHR_COMPANY_ID" => "112") do
      @server.call_tool("jethr_employee", { "employee_id" => "638" })
    end

    assert_equal [:employee, "112", "638"], @fake.calls.last
  end

  test "payroll month is passed through as period" do
    with_env("JETHR_COMPANY_ID" => "112") do
      @server.call_tool("jethr_payroll", { "period" => "9-2026" })
      @server.call_tool("jethr_report", { "section" => "personale", "year" => 2026, "month" => 9 })
    end

    assert_equal [:payroll, "112", "9-2026", nil, nil, nil], @fake.calls[-2]
    assert_equal [:report, "112", "personale", 2026, 9], @fake.calls.last
  end

  test "auth status is the live company probe" do
    @server.persist_credentials!(
      "JETHR_COMPANY_ID" => "112",
      "JETHR_EMAIL" => "ada@example.com",
      "JETHR_MFA_PENDING" => nil,
    )

    status = @server.fetch_auth_status
    assert_equal true, status[:authenticated]
    assert_equal "112", status[:company_id]
    assert_equal "ada@example.com", status[:email]
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
