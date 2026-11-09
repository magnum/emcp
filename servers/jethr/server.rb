# frozen_string_literal: true

require_relative "jethr_client"

module Emcp
  module Servers
    module Jethr
      class Server < ::McpServer
        server_id "jethr"
        display_name "Jethr"
        description "Employees, payroll cycles, and company reports through the Jethr API."
        version "0.1.0"

        def instructions
          "Jethr tools call https://backend.jethr.com with the session saved at login. " \
            "Set JETHR_COMPANY_ID to the company number in the admin URL. " \
            "jethr_employees lists people in force. jethr_employee reads one person. " \
            "jethr_payrolls lists payroll cycles and jethr_payroll reads one month, such as 9-2026. " \
            "jethr_report reads one report section for a month."
        end

        def auth_help_content
          {
            title: "Sign in to Jethr",
            description: "EmCP signs in at POST /api/v1/auth/login/ with your Jethr email and password. " \
                         "The login response sets the session cookie. That session is stored on this instance " \
                         "and sent on later API calls. Leave the password blank to keep the one already saved.",
            steps: [
              "Use the same email and password you use at https://sso.jethr.com.",
              "Enter the company id from the admin URL, for example 112 in #/112/dipendenti.",
              "Save once with the security code empty. Jethr emails a 6-character code.",
              "Paste that code into Codice di sicurezza and save again.",
            ],
            commands: [],
            note: "Dopo la password Jethr invia un codice di 6 caratteri. Incollalo nel campo Codice di sicurezza e salva di nuovo. " \
                  "La password e la sessione restano cifrate su questa istanza.",
          }
        end

        def auth_fields
          [
            {
              name: "jethr_email",
              label: "Email",
              type: "text",
              required: true,
              help: "The email you use to sign in to Jethr.",
              env: "JETHR_EMAIL",
            },
            {
              name: "jethr_password",
              label: "Password",
              type: "password",
              required: true,
              help: "Leave blank to keep the saved password.",
              env: "JETHR_PASSWORD",
            },
            {
              name: "jethr_otp",
              label: "Codice di sicurezza",
              type: "text",
              required: false,
              help: "6 caratteri inviati via email dopo la password. Lascia vuoto al primo salvataggio.",
            },
            {
              name: "jethr_company_id",
              label: "Company id",
              type: "text",
              required: true,
              help: "The company number in the admin URL, for example 112 in #/112/dipendenti.",
              env: "JETHR_COMPANY_ID",
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
          if mfa_pending?
            return {
              authenticated: false,
              mfa_required: true,
              company_id: company_id,
              email: Emcp.sanitize_env_value(ENV["JETHR_EMAIL"]),
              error: Client::MFA_MESSAGE,
            }
          end

          probe = @client.probe(company_id: company_id)
          {
            authenticated: probe[:company_id].to_s == company_id,
            company_id: company_id,
            email: probe[:email],
          }
        rescue StandardError => e
          {
            authenticated: false,
            company_id: Emcp.sanitize_env_value(ENV["JETHR_COMPANY_ID"]),
            email: Emcp.sanitize_env_value(ENV["JETHR_EMAIL"]),
            error: e.message,
          }
        end

        def apply_credentials(params)
          load_credentials!
          email = params["jethr_email"].to_s.strip
          password = params["jethr_password"].to_s.strip
          company_id = params["jethr_company_id"].to_s.strip
          otp = params["jethr_otp"].to_s.strip
          raise "Company id is required" unless company_id.match?(/\A\d+\z/)
          raise "Email is required" if email.empty? && Emcp.sanitize_env_value(ENV["JETHR_EMAIL"]).empty?
          raise "Password is required" if password.empty? && Emcp.sanitize_env_value(ENV["JETHR_PASSWORD"]).empty?

          updates = { "JETHR_COMPANY_ID" => company_id }
          updates["JETHR_EMAIL"] = email if email.present?
          updates["JETHR_PASSWORD"] = password if password.present?

          if otp.present?
            persist_credentials!(updates)
            replace_client!
            @client.submit_otp!(otp)
            mark_mfa_pending!(false)
            confirm_login!
          elsif mfa_pending? && password.empty?
            raise Client::MFA_MESSAGE
          else
            persist_credentials!(
              updates.merge(
                "JETHR_SESSION" => nil,
                "JETHR_CSRF" => nil,
                "JETHR_TOKEN" => nil,
                "JETHR_MFA_PENDING" => nil,
              ),
            )
            replace_client!
            @client.login!
            if @client.mfa_challenge?
              mark_mfa_pending!(true)
              raise Client::MFA_MESSAGE
            end

            mark_mfa_pending!(false)
            confirm_login!
          end
        ensure
          password = nil
          otp = nil
        end

        def clear_credentials!
          persist_credentials!(
            "JETHR_EMAIL" => nil,
            "JETHR_PASSWORD" => nil,
            "JETHR_COMPANY_ID" => nil,
            "JETHR_SESSION" => nil,
            "JETHR_CSRF" => nil,
            "JETHR_TOKEN" => nil,
            "JETHR_MFA_PENDING" => nil,
          )
          replace_client!
        end

        def persist_session!(session:, csrf:, token:)
          persist_credentials!(
            "JETHR_SESSION" => session,
            "JETHR_CSRF" => csrf,
            "JETHR_TOKEN" => token,
          )
        end

        def mark_mfa_pending!(pending)
          persist_credentials!("JETHR_MFA_PENDING" => pending ? "true" : nil)
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

          define_tool(
            name: "jethr_payrolls",
            description: "List payroll cycles (cedolini) for the company. Each row is one month: description, year, " \
                         "status, due date, and amounts shown on the cedolini page.",
            properties: {
              company_id: string_prop("Company id. Defaults to JETHR_COMPANY_ID."),
              offset: integer_prop("Number of cycles to skip. Default 0."),
              limit: integer_prop("Page size, default 40, maximum 80."),
            },
          ) do |company_id: nil, offset: 0, limit: nil|
            api_response(
              @client.payrolls(
                company_id: company_id.presence || required_company_id,
                offset: offset,
                limit: limit,
              ),
            )
          end

          define_tool(
            name: "jethr_payroll",
            description: "Read one payroll month, the same page as cedolini/9-2026. " \
                         "Pass period as month-year, for example 9-2026. Includes the payslips of that cycle.",
            properties: {
              period: string_prop("Month-year as in the admin URL, for example 9-2026."),
              year: integer_prop("Year, used when period is omitted."),
              month: integer_prop("Month 1-12, used when period is omitted."),
              company_id: string_prop("Company id. Defaults to JETHR_COMPANY_ID."),
              limit: integer_prop("Maximum payslip rows, default 40, maximum 80."),
            },
          ) do |period: nil, year: nil, month: nil, company_id: nil, limit: nil|
            api_response(
              @client.payroll(
                company_id: company_id.presence || required_company_id,
                period: period,
                year: year,
                month: month,
                limit: limit,
              ),
            )
          end

          define_tool(
            name: "jethr_report",
            description: "Read one company report for a month. section is personale, presenze-assenze, rimborsi-spese, " \
                         "costo-aziendale, trasparenza-retributiva, or tfr-azienda. " \
                         "Omit year and month to use the latest period Jethr publishes. " \
                         "Tables return the first 25 rows.",
            properties: {
              section: string_prop("Report slug: personale, presenze-assenze, rimborsi-spese, costo-aziendale, trasparenza-retributiva, tfr-azienda."),
              year: integer_prop("Year. Omit with month to use the latest period."),
              month: integer_prop("Month 1-12. Omit with year to use the latest period."),
              company_id: string_prop("Company id. Defaults to JETHR_COMPANY_ID."),
            },
            required: ["section"],
          ) do |section:, year: nil, month: nil, company_id: nil|
            api_response(
              @client.report(
                company_id: company_id.presence || required_company_id,
                section: section,
                year: year,
                month: month,
              ),
            )
          end
        end

        def replace_client!
          @client = Client.new(on_session: method(:persist_session!), on_mfa: method(:mark_mfa_pending!))
        end

        def credential_env_keys
          %w[JETHR_EMAIL JETHR_PASSWORD JETHR_COMPANY_ID JETHR_SESSION JETHR_CSRF JETHR_TOKEN JETHR_MFA_PENDING]
        end

        private

        def confirm_login!
          status = auth_status(force: true)
          return true if status[:authenticated]

          detail = status[:error].to_s.strip
          raise(detail.empty? ? "Jethr rejected the login" : "Jethr rejected the login: #{detail}")
        end

        def mfa_pending?
          ActiveModel::Type::Boolean.new.cast(Emcp.sanitize_env_value(ENV["JETHR_MFA_PENDING"]))
        end

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
