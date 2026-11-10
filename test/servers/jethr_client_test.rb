# frozen_string_literal: true

require "test_helper"

class JethrClientTest < ActiveSupport::TestCase
  setup do
    @server = mcp_server_for("jethr")
  end

  test "in-force list targets the company employees endpoint" do
    client = Emcp::Servers::Jethr::Client.new

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

  test "payroll and report urls follow the admin pages" do
    client = Emcp::Servers::Jethr::Client.new

    assert_equal(
      "https://backend.jethr.com/api/v1/payrolls/?company=112&expand_provisional=true",
      client.payrolls_url("112"),
    )
    assert_equal(
      "https://backend.jethr.com/api/v1/payrolls/get_by_year_monthly_pay/112/2026/9/?expand_provisional=true",
      client.payroll_url("112", 2026, 9),
    )
    requests = client.report_requests("personale", "112", 2026, 9).to_h
    assert_equal(
      "https://backend.jethr.com/api/v1/monthly_reports/?company=112&month=9&scope=age&year=2026",
      requests["age"],
    )
    assert_equal(
      "https://backend.jethr.com/api/v1/employee_monthly_reports/?company=112&from_year_month=2026-9&scope=person&to_year_month=2026-9",
      requests["employees"],
    )
    expenses = client.report_requests("rimborsi-spese", "112", 2026, "09").to_h
    assert_includes expenses["expenses"], "status=APPROVED"
    assert_includes expenses["expenses"], "from_year_month=2026-9"
    tfr = client.report_requests("tfr-azienda", "112", 2026, 9).to_h
    assert_includes tfr["tfr"], "scope=tfr"
    assert_equal %w[gender_pay_gap], client.report_requests("trasparenza-retributiva", "112", 2026, 9).map(&:first)
  end

  test "employees uses the saved session and returns a short row" do
    seen = nil
    http = lambda do |_method, uri, headers, _body|
      seen = [uri.to_s, headers["Cookie"]]
      { status: 200, body: [{ "id" => 638, "full_name" => "Ada", "in_day_job_title" => "Dev", "ssn" => "hidden" }], cookies: {} }
    end
    client = Emcp::Servers::Jethr::Client.new(http: http)

    with_env("JETHR_SESSION" => "sess-1", "JETHR_CSRF" => "csrf-1") do
      page = client.employees(company_id: "112")
      assert_equal 1, page["total"]
      assert_equal 638, page.dig("employees", 0, "id")
      assert_equal "Dev", page.dig("employees", 0, "job_title")
      refute page.dig("employees", 0).key?("ssn")
    end
    assert_includes seen[0], "/api/v1/employees/"
    assert_includes seen[1], "sessionid=sess-1"
    refute_includes seen[1], "hidden"
  end

  test "login stores the session cookie from the response" do
    saved = []
    http = lambda do |method, uri, headers, body|
      if method == :get
        { status: 200, body: {}, cookies: { "csrftoken" => "csrf-1" } }
      else
        assert_equal "/api/v1/auth/login/", uri.path
        assert_equal "ada@example.com", body["email"]
        assert_equal "csrf-1", headers["X-CSRFTOKEN"]
        { status: 200, body: {}, cookies: { "sessionid" => "sess-1", "csrftoken" => "csrf-2" } }
      end
    end
    client = Emcp::Servers::Jethr::Client.new(http: http, on_session: ->(session:, csrf:, token:) { saved << [session, csrf, token] })

    with_env("JETHR_EMAIL" => "ada@example.com", "JETHR_PASSWORD" => "secret", "JETHR_SESSION" => "", "JETHR_CSRF" => "", "JETHR_TOKEN" => "") do
      client.sign_in!
    end
    assert_equal [["sess-1", "csrf-2", nil]], saved
  end

  test "a password login that still cannot read the profile needs the email code" do
    http = lambda do |method, uri, headers, body|
      if method == :get && uri.path == "/api/v1/auth/login/"
        { status: 200, body: {}, cookies: { "csrftoken" => "csrf-1" } }
      elsif method == :post && uri.path == "/api/v1/auth/login/"
        assert_equal "csrf-1", headers["X-CSRFTOKEN"]
        { status: 200, body: {}, cookies: { "sessionid" => "pre-mfa", "csrftoken" => "csrf-2" } }
      elsif uri.path == "/api/v1/persons/self/"
        { status: 403, body: { "detail" => "hidden" }, cookies: {} }
      else
        { status: 403, body: { "detail" => "secret" }, cookies: {} }
      end
    end
    flags = []
    client = Emcp::Servers::Jethr::Client.new(http: http, on_mfa: ->(pending:) { flags << pending })

    with_env(
      "JETHR_EMAIL" => "ada@example.com",
      "JETHR_PASSWORD" => "secret",
      "JETHR_SESSION" => "",
      "JETHR_CSRF" => "",
      "JETHR_MFA_PENDING" => "",
    ) do
      client.sign_in!
      assert client.mfa_challenge?
      ENV["JETHR_MFA_PENDING"] = "true"
      error = assert_raises(RuntimeError) { client.employee(company_id: "112", employee_id: "638") }
      assert_match(/codice di 6 caratteri/i, error.message)
      refute_match(/secret/, error.message)
    end
    assert_empty flags
  end

  test "the security code is posted to the mfa endpoint" do
    http = lambda do |method, uri, _headers, body|
      if method == :post && uri.path == "/api/v1/auth/validate_mfa_otp/"
        assert_equal "AB12CD", body["otp"]
        { status: 200, body: {}, cookies: { "sessionid" => "full" } }
      elsif uri.path == "/api/v1/persons/self/"
        { status: 200, body: { "id" => 1 }, cookies: {} }
      else
        { status: 500, body: {}, cookies: {} }
      end
    end
    saved = []
    client = Emcp::Servers::Jethr::Client.new(
      http: http,
      on_session: ->(session:, csrf:, token:) { saved << session },
    )

    with_env("JETHR_SESSION" => "pre-mfa", "JETHR_CSRF" => "csrf-1", "JETHR_MFA_PENDING" => "true") do
      client.submit_otp!("ab12cd")
      refute client.mfa_challenge?
    end
    assert_equal "full", saved.last
  end

  test "a rejected session does not include the response body or start a new login" do
    posts = 0
    http = lambda do |method, uri, _headers, _body|
      posts += 1 if method == :post && uri.path == "/api/v1/auth/login/"
      { status: 403, body: { "detail" => "secret" }, cookies: {} }
    end
    client = Emcp::Servers::Jethr::Client.new(http: http)

    error = assert_raises(RuntimeError) do
      with_env(
        "JETHR_SESSION" => "sess-1",
        "JETHR_CSRF" => "csrf-1",
        "JETHR_EMAIL" => "ada@example.com",
        "JETHR_PASSWORD" => "secret",
        "JETHR_MFA_PENDING" => "",
      ) do
        client.employee(company_id: "112", employee_id: "638")
      end
    end
    assert_match(/session expired/, error.message)
    refute_match(/secret/, error.message)
    assert_equal 0, posts
  end

  test "a forbidden contractor report does not expire the session" do
    http = lambda do |_method, uri, _headers, _body|
      if uri.path.include?("contractor")
        { status: 403, body: { "detail" => "Non hai l'autorizzazione" }, cookies: {} }
      elsif uri.path.include?("employee_monthly_reports")
        { status: 200, body: [{ "first_name" => "Ada", "business_cost" => "1", "ssn" => "hidden" }], cookies: {} }
      else
        { status: 200, body: { "is_empty" => false }, cookies: {} }
      end
    end
    client = Emcp::Servers::Jethr::Client.new(http: http)

    report = with_env("JETHR_SESSION" => "sess-1", "JETHR_CSRF" => "csrf-1", "JETHR_MFA_PENDING" => "") do
      client.report(company_id: "112", section: "costo-aziendale", year: 2026, month: 9)
    end

    assert_equal 403, report.dig("parts", "staff", "status")
    assert_equal 403, report.dig("parts", "contractors", "status")
    assert_equal "Ada", report.dig("parts", "employees", 0, "first_name")
    assert_equal "1", report.dig("parts", "employees", 0, "business_cost")
    refute report.dig("parts", "employees", 0).key?("ssn")
  end

  test "ids must be numeric" do
    client = Emcp::Servers::Jethr::Client.new

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
