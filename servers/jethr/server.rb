# frozen_string_literal: true

require_relative "jethr_client"

module Emcp
  module Servers
    module Jethr
      class Server < ::McpServer
        server_id "jethr"
        display_name "Jethr"
        description "Employee list and employee detail from a signed-in Jethr admin tab."
        version "0.1.0"

        def instructions
          "Jethr has no API token. These tools reuse the Chrome session already signed in at " \
            "https://admin.jethr.com. Pair a Browser instance, leave that admin tab open, and set " \
            "JETHR_COMPANY_ID. jethr_employees lists people in force. jethr_employee reads one person. " \
            "The session cookie stays in Chrome."
        end

        def auth_help_content
          {
            title: "Connect Jethr through the signed-in browser",
            description: "The admin app authenticates with an HttpOnly session cookie and a CSRF cookie. " \
                         "Page JavaScript cannot read the session, and there is no bearer token to paste. " \
                         "EmCP calls https://backend.jethr.com from the admin tab that the paired Chrome extension can see.",
            steps: [
              "Pair a Browser instance in the Chrome profile that is signed in to Jethr.",
              "Turn on Allow page JavaScript for that browser instance.",
              "Leave a tab open on https://admin.jethr.com.",
              "Enter the company id from the admin URL (the number after #/) and, if you have more than one browser, its instance id.",
            ],
            commands: [],
            note: "Saving this form stores the company id and the browser instance id. It does not copy the session cookie. " \
                  "Sign in again in that Chrome window when the session expires.",
          }
        end

        def auth_fields
          [
            {
              name: "jethr_company_id",
              label: "Company id",
              type: "text",
              required: true,
              help: "The company number in the admin URL, for example 112 in #/112/dipendenti.",
              env: "JETHR_COMPANY_ID",
            },
            {
              name: "jethr_browser_server_id",
              label: "Browser instance id",
              type: "text",
              required: false,
              help: "Numeric id of the paired Browser instance. Leave blank to use your first browser instance.",
              env: "JETHR_BROWSER_SERVER_ID",
            },
          ]
        end

        def auth_status_cache_ttl = 120

        def emcp_service_info
          fetch_auth_status
        end

        def fetch_auth_status
          load_credentials!
          company_id = required_company_id
          probe = @client.probe(company_id: company_id)
          {
            authenticated: probe[:company_id].to_s == company_id,
            company_id: company_id,
            browser_server_id: probe[:browser_server_id],
            tab_id: probe[:tab_id],
          }
        rescue StandardError => e
          {
            authenticated: false,
            company_id: Emcp.sanitize_env_value(ENV["JETHR_COMPANY_ID"]),
            browser_server_id: Emcp.sanitize_env_value(ENV["JETHR_BROWSER_SERVER_ID"]),
            error: e.message,
          }
        end

        def apply_credentials(params)
          company_id = params["jethr_company_id"].to_s.strip
          browser_id = params["jethr_browser_server_id"].to_s.strip
          raise "Company id is required" unless company_id.match?(/\A\d+\z/)
          raise "Browser instance id must be numeric" if browser_id.present? && !browser_id.match?(/\A\d+\z/)

          apply_credentials_probe!(
            {
              "JETHR_COMPANY_ID" => company_id,
              "JETHR_BROWSER_SERVER_ID" => browser_id,
            },
            rejection_message: "Jethr session was rejected",
          )
        end

        def clear_credentials!
          persist_credentials!(
            "JETHR_COMPANY_ID" => nil,
            "JETHR_BROWSER_SERVER_ID" => nil,
          )
          replace_client!
        end

        def configure_tools
          define_tool(
            name: "jethr_employees",
            description: "List employees for the configured company. Defaults to people in force (tab-in-forza). " \
                         "Returns a short row per person: id, name, job title, work email, and contract dates.",
            properties: {
              company_id: string_prop("Company id. Defaults to JETHR_COMPANY_ID."),
              status: string_prop("in_force (default) or all."),
              offset: integer_prop("Number of rows to skip. Default 0."),
              limit: integer_prop("Page size, default 40, maximum 80."),
            },
          ) do |company_id: nil, status: nil, offset: 0, limit: nil|
            api_response(
              @client.employees(
                company_id: company_id.presence || required_company_id,
                status: status,
                offset: offset,
                limit: limit,
              ),
            )
          end

          define_tool(
            name: "jethr_employee",
            description: "Read one employee, the same record as the panoramica tab. " \
                         "Pass the id from jethr_employees or from the admin URL.",
            properties: {
              employee_id: string_prop("Employee id, for example 638."),
              company_id: string_prop("Company id. Defaults to JETHR_COMPANY_ID."),
            },
            required: ["employee_id"],
          ) do |employee_id:, company_id: nil|
            api_response(
              @client.employee(
                company_id: company_id.presence || required_company_id,
                employee_id: employee_id,
              ),
            )
          end
        end

        def replace_client!
          @client = Client.new(self)
        end

        def credential_env_keys
          %w[JETHR_COMPANY_ID JETHR_BROWSER_SERVER_ID]
        end

        private

        def required_company_id
          raw = Emcp.sanitize_env_value(ENV["JETHR_COMPANY_ID"])
          raise "JETHR_COMPANY_ID is required" unless raw.match?(/\A\d+\z/)

          raw
        end
      end
    end
  end
end

Emcp.register_integration(Emcp::Servers::Jethr::Server)
