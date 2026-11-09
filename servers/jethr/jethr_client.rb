# frozen_string_literal: true

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
              fetch(#{url.to_json}, {
                credentials: "include",
                headers: { Accept: "application/json", "X-CSRFTOKEN": csrf }
              }).then(async (response) => {
                const text = await response.text();
                let body = null;
                try { body = JSON.parse(text); } catch (_error) { body = null; }
                let payload = body;
                if (response.ok && mode === "list") {
                  const rows = Array.isArray(body) ? body : ((body && body.results) || []);
                  payload = { total: rows.length, offset, employees: rows.slice(offset, offset + limit).map(compact) };
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
      end
    end
  end
end
