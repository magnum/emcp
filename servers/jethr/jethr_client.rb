# frozen_string_literal: true

require "cgi"
require "json"
require "securerandom"

module Emcp
  module Servers
    module Jethr
      class Client
        API_ORIGIN = "https://backend.jethr.com"
        ADMIN_ORIGIN = "https://admin.jethr.com"
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

        def initialize(server, relay: nil)
          @server = server
          @relay = relay
        end

        def probe(company_id:)
          tab = jethr_tab
          body = request_json(company_url(company_id), tab_id: tab.fetch("tab_id"), mode: "company")
          {
            company_id: body["id"].presence || company_id,
            browser_server_id: browser_server.id,
            tab_id: tab["tab_id"],
          }
        end

        def employees(company_id:, status: "in_force", offset: 0, limit: LIST_LIMIT)
          status = normalize_status(status)
          offset = normalize_offset(offset)
          limit = normalize_limit(limit)
          tab = jethr_tab
          body = request_json(
            employees_url(company_id, status),
            tab_id: tab.fetch("tab_id"),
            mode: "list",
            offset: offset,
            limit: limit,
          )
          body.merge("company_id" => company_id, "status" => status)
        end

        def employee(company_id:, employee_id:)
          employee_id = normalize_id(employee_id, label: "employee id")
          tab = jethr_tab
          body = request_json(employee_url(employee_id), tab_id: tab.fetch("tab_id"), mode: "detail")
          body.merge("company_id" => company_id.to_s)
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
          tab = jethr_tab
          body = request_json(
            payrolls_url(company_id),
            tab_id: tab.fetch("tab_id"),
            mode: "payrolls",
            offset: offset,
            limit: limit,
          )
          body.merge("company_id" => company_id)
        end

        def payroll(company_id:, period: nil, year: nil, month: nil, limit: LIST_LIMIT)
          company_id = normalize_id(company_id, label: "company id")
          year, month = parse_payroll_period(period, year, month)
          limit = normalize_limit(limit)
          tab = jethr_tab
          cycle = request_json(
            payroll_url(company_id, year, month),
            tab_id: tab.fetch("tab_id"),
            mode: "payroll",
          )
          payslips = if cycle["id"].present?
            request_json(
              payslips_url(cycle["id"]),
              tab_id: tab.fetch("tab_id"),
              mode: "payslips",
              limit: limit,
            )
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
          parts = request_batch(report_requests(section, company_id, year, month))
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
          rows = case section
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
          rows
        end

        private

        def request_json(url, tab_id:, mode:, offset: 0, limit: LIST_LIMIT)
          token = SecureRandom.hex(8)
          eval_json(start_expression(url, token, mode, offset, limit), tab_id: tab_id)
          state = poll_json(token, tab_id: tab_id)
          cleanup(token, tab_id: tab_id)
          raise state["error"].to_s if state["error"].present?
          raise session_error(state["status"]) unless state["status"].to_i.between?(200, 299)
          raise "Jethr returned a non-JSON response" if state["parse_error"]

          body = state["body"]
          raise "Jethr returned an empty response" unless body.is_a?(Hash)

          body
        end

        def request_batch(requests)
          tab = jethr_tab
          token = SecureRandom.hex(8)
          eval_json(batch_expression(requests, token), tab_id: tab.fetch("tab_id"))
          state = poll_json(token, tab_id: tab.fetch("tab_id"))
          cleanup(token, tab_id: tab.fetch("tab_id"))
          raise state["error"].to_s if state["error"].present?

          parts = {}
          Array(state.dig("body", "parts")).each do |part|
            status = part["status"].to_i
            raise session_error(status) if [401, 403].include?(status)

            parts[part["name"]] = if status.between?(200, 299)
              part["body"]
            elsif part["error"].present?
              { "status" => status, "error" => part["error"].to_s }
            else
              { "status" => status }
            end
          end
          parts
        end

        def latest_period(company_id)
          tab = jethr_tab
          body = request_json(periods_url(company_id), tab_id: tab.fetch("tab_id"), mode: "periods")
          row = Array(body["periods"]).first
          raise "Jethr has no report period for this company" unless row.is_a?(Hash)

          normalize_period(row["year"], row["month"])
        end

        def poll_json(token, tab_id:)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 12
          loop do
            state = eval_json(poll_expression(token), tab_id: tab_id)
            return state if state.is_a?(Hash) && state["pending"] == false
            raise "Jethr page did not answer" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

            sleep 0.25
          end
        end

        def cleanup(token, tab_id:)
          eval_json(cleanup_expression(token), tab_id: tab_id)
        rescue StandardError
          nil
        end

        def eval_json(expression, tab_id:)
          result = relay("browser_eval_readonly", { "expression" => expression, "tab_id" => tab_id }, timeout: 20)
          raw = result.is_a?(Hash) ? result["value"].to_s : result.to_s
          raise "Jethr page result was truncated" if raw.end_with?("…")

          parsed = JSON.parse(raw)
          parsed.is_a?(Hash) ? parsed : { "value" => parsed }
        rescue JSON::ParserError
          raise "Jethr page returned an unreadable result"
        end

        def jethr_tab
          result = relay("browser_list_tabs", {}, timeout: 15)
          tabs = result.is_a?(Hash) ? Array(result["tabs"]) : []
          admin = tabs.select { |tab| tab["url"].to_s.match?(%r{\Ahttps://admin\.jethr\.com(?:/|\z)}i) }
          raise "Open #{ADMIN_ORIGIN} in the paired Chrome window and stay signed in" if admin.empty?

          company_id = Emcp.sanitize_env_value(ENV["JETHR_COMPANY_ID"])
          marker = "/#{company_id}/"
          (company_id.present? && admin.find { |tab| tab["url"].to_s.include?(marker) }) || admin.first
        end

        def relay(tool, args, timeout:)
          return @relay.call(tool, args, timeout: timeout) if @relay

          Emcp::Servers::Browser::Client.new(browser_server).call(
            tool,
            args,
            require_local: false,
            timeout: timeout,
          )
        end

        def browser_server
          return @browser_server if defined?(@browser_server) && @browser_server

          scope = ::McpServer.joins(:mcp_server_type).where(
            user_id: @server.user_id,
            mcp_server_types: { code: "browser" },
          )
          raw = Emcp.sanitize_env_value(ENV["JETHR_BROWSER_SERVER_ID"])
          record = raw.empty? ? scope.order(:id).first : scope.find_by(id: raw)
          raise "Choose a browser instance you own" unless record

          @browser_server = record
        end

        def session_error(status)
          code = status.to_i
          if [401, 403].include?(code)
            "Jethr session expired. Open #{ADMIN_ORIGIN} in the paired Chrome window and sign in again."
          else
            "Jethr API returned #{code}"
          end
        end

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

        def start_expression(url, token, mode, offset, limit)
          <<~JS
            (() => {
              const token = #{token.to_json};
              const mode = #{mode.to_json};
              const offset = #{offset.to_i};
              const limit = #{limit.to_i};
              window.__emcpJethr = window.__emcpJethr || {};
              window.__emcpJethr[token] = { pending: true };
              const row = document.cookie.split("; ").find((item) => item.startsWith("csrftoken="));
              const csrf = row ? decodeURIComponent(row.slice("csrftoken=".length)) : "";
              const compact = (person) => ({
                id: person.id,
                full_name: person.full_name,
                first_name: person.first_name,
                last_name: person.last_name,
                job_title: person.in_day_job_title,
                work_email: person.work_email,
                contract_start: person.in_day_contract_start_date,
                contract_end: person.in_day_contract_end_date,
                employee_kind: person.employee_kind,
                registration_status: person.registration_status
              });
              const compactPayroll = (row) => {
                if (!row || typeof row !== "object") return row;
                if (JSON.stringify(row).length <= 8000) return row;
                const keep = ["id", "description", "year", "monthly_pay", "status", "due_date", "monthly_kind", "expected_payslips_available_date", "expected_start_elaboration_date", "f24_amount", "was_set_back_as_draft"];
                const out = { truncated: true };
                keep.forEach((key) => { if (row[key] !== undefined) out[key] = row[key]; });
                return out;
              };
              const compactPayslip = (row) => {
                const out = {};
                Object.keys(row || {}).forEach((key) => {
                  const value = row[key];
                  if (value == null || ["string", "number", "boolean"].includes(typeof value)) out[key] = value;
                });
                if (row && row.employee && typeof row.employee === "object") {
                  out.employee = { id: row.employee.id, full_name: row.employee.full_name };
                }
                return out;
              };
              const rowsOf = (body) => Array.isArray(body) ? body : ((body && body.results) || []);
              fetch(#{url.to_json}, {
                credentials: "include",
                headers: { Accept: "application/json", "X-CSRFTOKEN": csrf }
              }).then(async (response) => {
                const text = await response.text();
                let body = null;
                try { body = JSON.parse(text); } catch (_error) { body = null; }
                let payload = body;
                if (response.ok && mode === "list") {
                  const rows = rowsOf(body);
                  payload = { total: rows.length, offset, employees: rows.slice(offset, offset + limit).map(compact) };
                } else if (response.ok && mode === "payrolls") {
                  const rows = rowsOf(body);
                  payload = { total: rows.length, offset, payrolls: rows.slice(offset, offset + limit).map(compactPayroll) };
                } else if (response.ok && mode === "payroll") {
                  payload = compactPayroll(body);
                } else if (response.ok && mode === "payslips") {
                  const rows = rowsOf(body);
                  payload = { total: rows.length, payslips: rows.slice(0, limit).map(compactPayslip) };
                } else if (response.ok && mode === "periods") {
                  payload = { periods: rowsOf(body).slice(0, 24).map((row) => ({ year: row.year, month: row.month })) };
                } else if (response.ok && mode === "company") {
                  payload = { id: body && body.id };
                } else if (response.ok && mode === "detail" && body && JSON.stringify(body).length > 10000) {
                  payload = Object.assign(compact(body), { truncated: true });
                }
                window.__emcpJethr[token] = {
                  pending: false,
                  status: response.status,
                  body: payload,
                  parse_error: body == null
                };
              }).catch((error) => {
                window.__emcpJethr[token] = { pending: false, error: String((error && error.message) || error) };
              });
              return { started: true };
            })()
          JS
        end

        def poll_expression(token)
          "(window.__emcpJethr && window.__emcpJethr[#{token.to_json}]) || { pending: true }"
        end

        def cleanup_expression(token)
          "(() => { if (window.__emcpJethr) delete window.__emcpJethr[#{token.to_json}]; return { deleted: true }; })()"
        end

        def batch_expression(requests, token)
          jobs = requests.map { |name, url| { "name" => name, "url" => url } }
          <<~JS
            (() => {
              const token = #{token.to_json};
              const jobs = #{JSON.generate(jobs)};
              window.__emcpJethr = window.__emcpJethr || {};
              window.__emcpJethr[token] = { pending: true };
              const row = document.cookie.split("; ").find((item) => item.startsWith("csrftoken="));
              const csrf = row ? decodeURIComponent(row.slice("csrftoken=".length)) : "";
              const fit = (value, depth) => {
                if (depth > 5) return null;
                if (Array.isArray(value)) {
                  const rows = value.slice(0, 25).map((item) => fit(item, depth + 1));
                  return value.length > 25 ? { total: value.length, rows } : rows;
                }
                if (value && typeof value === "object") {
                  const keys = Object.keys(value);
                  if (keys.length > 40) return { key_count: keys.length, truncated: true };
                  const out = {};
                  keys.forEach((key) => { out[key] = fit(value[key], depth + 1); });
                  return out;
                }
                return value;
              };
              Promise.all(jobs.map(async (job) => {
                try {
                  const response = await fetch(job.url, {
                    credentials: "include",
                    headers: { Accept: "application/json", "X-CSRFTOKEN": csrf }
                  });
                  const text = await response.text();
                  let body = null;
                  try { body = JSON.parse(text); } catch (_error) { body = null; }
                  let payload = response.ok && body != null ? fit(body, 0) : null;
                  if (payload && JSON.stringify(payload).length > 4000) {
                    payload = { truncated: true, kind: Array.isArray(body) ? "array" : "object" };
                  }
                  return { name: job.name, status: response.status, body: payload };
                } catch (error) {
                  return { name: job.name, status: 0, error: String((error && error.message) || error) };
                }
              })).then((parts) => {
                window.__emcpJethr[token] = { pending: false, status: 200, body: { parts } };
              });
              return { started: true };
            })()
          JS
        end
      end
    end
  end
end
