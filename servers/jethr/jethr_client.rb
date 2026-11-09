# frozen_string_literal: true

require "cgi"
require "json"
require "net/http"
require "uri"

module Emcp
  module Servers
    module Jethr
      class Client
        API_ORIGIN = "https://backend.jethr.com"
        LOGIN_PATH = "/api/v1/auth/login/"
        STATUSES = %w[in_force all].freeze
        LIST_LIMIT = 40
        REPORT_SECTIONS = %w[
          personale
          presenze-assenze
          rimborsi-spese
          costo-aziendale
          trasparenza-retributiva
          tfr-azienda
        ].freeze
        PAYROLL_KEYS = %w[
          id description year monthly_pay status due_date monthly_kind
          expected_payslips_available_date expected_start_elaboration_date
          f24_amount was_set_back_as_draft
        ].freeze

        def initialize(on_session: nil, http: nil)
          @on_session = on_session
          @http = http
        end

        def ensure_session!
          return if session_present?

          login!
        end

        def probe(company_id:)
          ensure_session!
          body = get_json(company_url(company_id))
          {
            company_id: body.is_a?(Hash) ? body["id"].to_s.presence || company_id : company_id,
            email: email,
          }
        end

        def employees(company_id:, status: "in_force", offset: 0, limit: LIST_LIMIT)
          status = normalize_status(status)
          company_id = normalize_id(company_id, label: "company id")
          offset = normalize_offset(offset)
          limit = normalize_limit(limit)
          rows = rows_of(get_json(employees_url(company_id, status)))
          {
            "company_id" => company_id,
            "status" => status,
            "total" => rows.length,
            "offset" => offset,
            "employees" => rows.drop(offset).first(limit).map { |row| compact_employee(row) },
          }
        end

        def employee(company_id:, employee_id:)
          employee_id = normalize_id(employee_id, label: "employee id")
          body = get_json(employee_url(employee_id))
          raise "Jethr returned an empty response" unless body.is_a?(Hash)

          fit_record(body).merge("company_id" => company_id.to_s)
        end

        def employees_url(company_id, status)
          query = { "company" => normalize_id(company_id, label: "company id") }
          query["contract_status"] = "IN_FORCE" if normalize_status(status) == "in_force"
          "#{API_ORIGIN}/api/v1/employees/?#{query.to_query}"
        end

        def employee_url(employee_id)
          "#{API_ORIGIN}/api/v1/employees/#{normalize_id(employee_id, label: "employee id")}/"
        end

        def company_url(company_id)
          "#{API_ORIGIN}/api/v1/companies/#{normalize_id(company_id, label: "company id")}/"
        end

        def payrolls(company_id:, offset: 0, limit: LIST_LIMIT)
          company_id = normalize_id(company_id, label: "company id")
          offset = normalize_offset(offset)
          limit = normalize_limit(limit)
          rows = rows_of(get_json(payrolls_url(company_id)))
          {
            "company_id" => company_id,
            "total" => rows.length,
            "offset" => offset,
            "payrolls" => rows.drop(offset).first(limit).map { |row| compact_payroll(row) },
          }
        end

        def payroll(company_id:, period: nil, year: nil, month: nil, limit: LIST_LIMIT)
          company_id = normalize_id(company_id, label: "company id")
          year, month = parse_payroll_period(period, year, month)
          limit = normalize_limit(limit)
          cycle = get_json(payroll_url(company_id, year, month))
          raise "Jethr returned an empty response" unless cycle.is_a?(Hash)

          cycle = compact_payroll(cycle)
          payslips = if cycle["id"].present?
            rows = rows_of(get_json(payslips_url(cycle["id"])))
            { "total" => rows.length, "payslips" => rows.first(limit).map { |row| compact_payslip(row) } }
          else
            { "total" => 0, "payslips" => [] }
          end
          {
            "company_id" => company_id,
            "year" => year.to_i,
            "month" => month.to_i,
            "payroll" => cycle,
            "payslips" => payslips,
          }
        end

        def report(company_id:, section:, year: nil, month: nil)
          section = normalize_section(section)
          company_id = normalize_id(company_id, label: "company id")
          year, month = if year.to_s.strip.empty? && month.to_s.strip.empty?
            latest_period(company_id)
          else
            normalize_period(year, month)
          end
          parts = {}
          report_requests(section, company_id, year, month).each do |name, url|
            parts[name] = report_part(url)
          end
          {
            "company_id" => company_id,
            "section" => section,
            "year" => year.to_i,
            "month" => month.to_i,
            "parts" => parts,
          }
        end

        def payrolls_url(company_id)
          endpoint("payrolls", "company" => normalize_id(company_id, label: "company id"), "expand_provisional" => "true")
        end

        def payroll_url(company_id, year, month)
          year, month = normalize_period(year, month)
          company_id = normalize_id(company_id, label: "company id")
          "#{API_ORIGIN}/api/v1/payrolls/get_by_year_monthly_pay/#{company_id}/#{year}/#{month}/?expand_provisional=true"
        end

        def payslips_url(payroll_id)
          endpoint("payslips", "payroll" => normalize_id(payroll_id, label: "payroll id"), "scope" => "payroll")
        end

        def periods_url(company_id)
          endpoint("monthly_reports/periods", "company" => normalize_id(company_id, label: "company id"))
        end

        def report_requests(section, company_id, year, month)
          section = normalize_section(section)
          company_id = normalize_id(company_id, label: "company id")
          year, month = normalize_period(year, month)
          case section
          when "personale"
            [
              ["age", monthly_url("monthly_reports", company_id, year, month, "age")],
              ["gender", monthly_url("monthly_reports", company_id, year, month, "gender")],
              ["in_out", monthly_url("monthly_reports", company_id, year, month, "in-out")],
              ["contract", monthly_url("monthly_reports", company_id, year, month, "contract")],
              ["employees", range_url("employee_monthly_reports", company_id, year, month, "person")],
              ["contractors", range_url("contractor_monthly_reports", company_id, year, month, "person")],
            ]
          when "presenze-assenze"
            [
              ["absences", monthly_url("monthly_reports", company_id, year, month, "absences")],
              ["residue", monthly_url("monthly_reports", company_id, year, month, "residue")],
              ["employees", range_url("employee_monthly_reports", company_id, year, month, "absence_request")],
              ["contractors", range_url("contractor_monthly_reports", company_id, year, month, "absence-requests")],
            ]
          when "rimborsi-spese"
            [
              ["monthly", monthly_url("expenses", company_id, year, month, "monthly")],
              ["current", monthly_url("expenses", company_id, year, month, "current")],
              ["expenses", range_url("expenses", company_id, year, month, nil, "expand_employee" => "true", "status" => "APPROVED")],
            ]
          when "costo-aziendale"
            [
              ["cost", monthly_url("monthly_reports", company_id, year, month, "cost")],
              ["cost_detail", monthly_url("monthly_reports", company_id, year, month, "cost-detail")],
              ["staff", monthly_url("contractor_staff_monthly_reports", company_id, year, month, "cost")],
              ["employees", range_url("employee_monthly_reports", company_id, year, month, "business-cost")],
              ["contractors", range_url("contractor_monthly_reports", company_id, year, month, "business-cost")],
            ]
          when "trasparenza-retributiva"
            [
              ["gender_pay_gap", monthly_url("monthly_reports", company_id, year, month, "gender-pay-gap")],
            ]
          when "tfr-azienda"
            [
              ["tfr", monthly_url("monthly_reports", company_id, year, month, "tfr")],
              ["employees", range_url("employee_monthly_reports", company_id, year, month, "tfr")],
            ]
          else
            raise "section must be #{REPORT_SECTIONS.join(", ")}"
          end
        end

        private

        def login!
          raise "JETHR_EMAIL is required" if email.empty?
          raise "JETHR_PASSWORD is required" if password.empty?

          jar = {}
          seeded = perform(:get, "#{API_ORIGIN}#{LOGIN_PATH}", auth: false, cookies: jar)
          jar.merge!(seeded[:cookies])
          posted = perform(
            :post,
            "#{API_ORIGIN}#{LOGIN_PATH}",
            auth: false,
            cookies: jar,
            body: { "email" => email, "password" => password },
          )
          jar.merge!(posted[:cookies])
          raise "Jethr rejected the email or password" if [401, 403].include?(posted[:status])
          raise "Jethr login returned #{posted[:status]}" unless posted[:status].between?(200, 299)

          token = token_from(posted[:body])
          session = jar["sessionid"].to_s
          csrf = jar["csrftoken"].to_s
          raise "Jethr login did not return a session" if session.empty? && token.empty?

          store_session!(session: session, csrf: csrf, token: token)
        end

        def store_session!(session:, csrf:, token:)
          ENV["JETHR_SESSION"] = session unless session.empty?
          ENV["JETHR_CSRF"] = csrf unless csrf.empty?
          ENV["JETHR_TOKEN"] = token unless token.to_s.empty?
          @on_session&.call(session: session, csrf: csrf, token: token)
        end

        def get_json(url)
          result = request_with_refresh(url)
          raise "Jethr session expired. Sign in again from the Jethr auth page." if [401, 403].include?(result[:status])
          raise "Jethr API returned #{result[:status]}" unless result[:status].between?(200, 299)
          raise "Jethr returned a non-JSON response" if result[:parse_error]
          raise "Jethr returned an empty response" unless result[:body].is_a?(Hash) || result[:body].is_a?(Array)

          result[:body]
        end

        def report_part(url)
          result = request_with_refresh(url)
          return fit(result[:body]) if result[:status].between?(200, 299) && !result[:parse_error]
          return { "status" => result[:status] } if result[:status] == 404

          raise "Jethr session expired. Sign in again from the Jethr auth page." if [401, 403].include?(result[:status])

          { "status" => result[:status] }
        end

        def request_with_refresh(url)
          ensure_session!
          result = perform(:get, url, auth: true, cookies: cookie_jar)
          return result unless [401, 403].include?(result[:status]) && can_login?

          login!
          perform(:get, url, auth: true, cookies: cookie_jar)
        end

        def perform(method, url, auth:, cookies:, body: nil)
          return @http.call(method, URI(url), request_headers(auth, cookies), body) if @http

          uri = URI(url)
          http_request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
          request_headers(auth, cookies).each { |key, value| http_request[key] = value }
          if body
            http_request["Content-Type"] = "application/json"
            http_request.body = JSON.generate(body)
          end
          response = Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: 20,
            read_timeout: 20,
            write_timeout: 20,
          ) { |http| http.request(http_request) }
          raw = response.body.to_s
          parsed = parse_json(raw)
          {
            status: response.code.to_i,
            body: parsed,
            parse_error: !raw.empty? && parsed.nil?,
            cookies: cookie_hash(response),
          }
        rescue Timeout::Error, SocketError, SystemCallError => e
          raise "Jethr request failed: #{e.message}"
        end

        def request_headers(auth, cookies)
          headers = { "Accept" => "application/json" }
          jar = cookies.dup
          jar["sessionid"] = session if auth && session.present?
          jar["csrftoken"] = csrf if auth && csrf.present?
          header_cookies = jar.compact_blank.map { |name, value| "#{name}=#{value}" }
          headers["Cookie"] = header_cookies.join("; ") if header_cookies.any?
          headers["X-CSRFTOKEN"] = jar["csrftoken"] if jar["csrftoken"].present?
          headers["Authorization"] = "Bearer #{token}" if auth && token.present?
          headers
        end

        def cookie_hash(response)
          Array(response.get_fields("set-cookie")).each_with_object({}) do |header, jar|
            pair = header.to_s.split(";", 2).first.to_s
            name, value = pair.split("=", 2)
            next if name.to_s.strip.empty? || value.nil?

            jar[name.strip] = value.strip.delete_prefix("\"").delete_suffix("\"")
          end
        end

        def parse_json(raw)
          return nil if raw.empty?

          JSON.parse(raw)
        rescue JSON::ParserError
          nil
        end

        def token_from(body)
          return nil unless body.is_a?(Hash)

          %w[token access_token access key].each do |key|
            value = body[key].to_s
            return value if value.present? && value.length < 2000 && !value.match?(/\s/)
          end
          nil
        end

        def latest_period(company_id)
          body = get_json(periods_url(company_id))
          row = rows_of(body).first
          raise "Jethr has no report period for this company" unless row.is_a?(Hash)

          normalize_period(row["year"], row["month"])
        end

        def rows_of(body)
          return body if body.is_a?(Array)
          return [] unless body.is_a?(Hash)

          return Array(body["results"]) if body.key?("results")
          return Array(body["periods"]) if body.key?("periods")

          []
        end

        def compact_employee(row)
          return {} unless row.is_a?(Hash)

          {
            "id" => row["id"],
            "full_name" => row["full_name"],
            "first_name" => row["first_name"],
            "last_name" => row["last_name"],
            "job_title" => row["in_day_job_title"],
            "work_email" => row["work_email"],
            "contract_start" => row["in_day_contract_start_date"],
            "contract_end" => row["in_day_contract_end_date"],
            "employee_kind" => row["employee_kind"],
            "registration_status" => row["registration_status"],
          }
        end

        def compact_payroll(row)
          return row unless row.is_a?(Hash)
          return row if JSON.generate(row).bytesize <= 8000

          kept = row.slice(*PAYROLL_KEYS)
          kept["truncated"] = true
          kept
        end

        def compact_payslip(row)
          return {} unless row.is_a?(Hash)

          out = row.select { |_, value| value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false }
          employee = row["employee"]
          if employee.is_a?(Hash)
            out["employee"] = { "id" => employee["id"], "full_name" => employee["full_name"] }
          end
          out
        end

        def fit(value, depth = 0)
          return nil if depth > 5

          case value
          when Array
            rows = value.first(25).map { |item| fit(item, depth + 1) }
            value.length > 25 ? { "total" => value.length, "rows" => rows } : rows
          when Hash
            return { "key_count" => value.size, "truncated" => true } if value.size > 40

            fitted = value.transform_values { |item| fit(item, depth + 1) }
            JSON.generate(fitted).bytesize > 4000 ? { "truncated" => true, "kind" => "object" } : fitted
          else
            value
          end
        end

        def fit_record(body)
          JSON.generate(body).bytesize <= 10_000 ? body : compact_employee(body).merge("truncated" => true)
        end

        def cookie_jar
          jar = {}
          jar["sessionid"] = session if session.present?
          jar["csrftoken"] = csrf if csrf.present?
          jar
        end

        def session_present?
          session.present? || token.present?
        end

        def can_login?
          email.present? && password.present?
        end

        def email = Emcp.sanitize_env_value(ENV["JETHR_EMAIL"])
        def password = Emcp.sanitize_env_value(ENV["JETHR_PASSWORD"])
        def session = Emcp.sanitize_env_value(ENV["JETHR_SESSION"])
        def csrf = Emcp.sanitize_env_value(ENV["JETHR_CSRF"])
        def token = Emcp.sanitize_env_value(ENV["JETHR_TOKEN"])

        def normalize_status(status)
          value = status.to_s.strip.presence || "in_force"
          raise "status must be in_force or all" unless STATUSES.include?(value)

          value
        end

        def normalize_id(value, label:)
          raw = value.to_s.strip
          raise "#{label} is required" unless raw.match?(/\A\d+\z/)

          raw
        end

        def normalize_offset(value)
          number = value.to_i
          number.negative? ? 0 : number
        end

        def normalize_limit(value)
          number = value.to_i
          number = LIST_LIMIT unless number.positive?
          [number, 80].min
        end

        def normalize_section(section)
          value = section.to_s.strip
          raise "section must be #{REPORT_SECTIONS.join(", ")}" unless REPORT_SECTIONS.include?(value)

          value
        end

        def normalize_period(year, month)
          year = year.to_s.strip
          month = month.to_s.strip.sub(/\A0+/, "")
          raise "year must be a four-digit year" unless year.match?(/\A20\d{2}\z/)
          raise "month must be 1-12" unless month.match?(/\A(?:[1-9]|1[0-2])\z/)

          [year, month]
        end

        def parse_payroll_period(period, year, month)
          text = period.to_s.strip
          if text.present?
            month_text, year_text = text.split("-", 2)
            return normalize_period(year_text, month_text)
          end

          normalize_period(year, month)
        end

        def monthly_url(resource, company_id, year, month, scope)
          endpoint(resource, "company" => company_id, "month" => month, "scope" => scope, "year" => year)
        end

        def range_url(resource, company_id, year, month, scope, extra = {})
          stamp = "#{year}-#{month}"
          params = { "company" => company_id, "from_year_month" => stamp, "to_year_month" => stamp }
          params["scope"] = scope if scope.present?
          endpoint(resource, params.merge(extra))
        end

        def endpoint(resource, params)
          query = params.sort.map { |key, value| "#{CGI.escape(key.to_s)}=#{CGI.escape(value.to_s)}" }.join("&")
          "#{API_ORIGIN}/api/v1/#{resource}/?#{query}"
        end
      end
    end
  end
end
