# frozen_string_literal: true

require "securerandom"
require_relative "origin_policy"
require_relative "session_registry"
require_relative "pairing"
require_relative "client"
require_relative "extension_zip"

module Emcp
  module Servers
    module Browser
      class Server < ::McpServer
        server_id "browser"
        display_name "Browser"
        description "Read and drive a signed-in Chrome window through an extension that connects out to this server."
        version "0.1.0"

        def instructions
          "Browser tools act on the Chrome window paired with this instance and reuse the user's existing login. " \
            "Allowed origins defaults to https://*/* (every HTTPS page). " \
            "A comma-separated list of Chrome match patterns narrows that. " \
            "Write tools (navigate, click, type, download) stay disabled unless Allow write is on for this instance. " \
            "browser_eval_readonly stays disabled unless Allow page JavaScript is on for this instance. " \
            "Prefer CSS selectors returned by browser_query or browser_accessibility_snapshot. " \
            "Timeouts use BROWSER_TIMEOUT (default 30 seconds)."
        end

        def auth_help_content
          {
            title: "Pair a Chrome window",
            description: "Install the eMCP Browser extension in the remote Chrome profile. " \
                         "It opens an outbound WebSocket to this server. No inbound port is required on that PC.",
            steps: [
              "Download the extension zip, unzip it, and load the folder at chrome://extensions with Developer mode.",
              "Allowed origins takes Chrome match patterns separated by commas. The default https://*/* allows every HTTPS site. Narrow it with https://host/* or *.example.it.",
              "Click Avvia pairing. Scan the QR code from the extension popup, or paste the pairing payload.",
              "After the first connection the extension reconnects with the saved token. Clear service credentials to revoke it."
            ],
            note: "Use on a company PC only with approval from IT and the data controller. " \
                  "Traffic stays on this self-hosted server. Write tools and page JavaScript evaluation are off by default."
          }
        end

        def auth_fields
          [
            {
              name: "browser_allowed_origins",
              label: "Allowed origins",
              type: "text",
              required: false,
              help: "Comma-separated Chrome match patterns. Default: https://*/*. Examples: https://edma.example.it/*, *.example.it, http://127.0.0.1:3000/*.",
              env: "BROWSER_ALLOWED_ORIGINS",
              value: -> {
                credential_hash["BROWSER_ALLOWED_ORIGINS"].presence ||
                  ENV["BROWSER_ALLOWED_ORIGINS"].presence ||
                  OriginPolicy::DEFAULT
              }
            },
            {
              name: "browser_allow_write",
              label: "Allow write",
              type: "checkbox",
              help: "Navigate, click, type, and download. Saved on this instance.",
              value: -> { allow_write? ? "true" : "false" }
            },
            {
              name: "browser_allow_eval",
              label: "Allow page JavaScript",
              type: "checkbox",
              help: "Enables browser_eval_readonly. The expression runs in the page and can change it.",
              env: "BROWSER_ALLOW_EVAL",
              value: -> { browser_flag("BROWSER_ALLOW_EVAL") ? "true" : "false" }
            },
            {
              name: "browser_timeout",
              label: "Tool timeout (seconds)",
              type: "number",
              help: "How long a tool waits for the extension. Default 30.",
              env: "BROWSER_TIMEOUT",
              value: -> { browser_number("BROWSER_TIMEOUT", "timeout", 30).to_s }
            },
            {
              name: "browser_ws_heartbeat",
              label: "Heartbeat (seconds)",
              type: "number",
              help: "How often the extension checks in. Default 15. Reconnect the extension after changing it.",
              env: "BROWSER_WS_HEARTBEAT",
              value: -> { browser_number("BROWSER_WS_HEARTBEAT", "heartbeat", 15).to_s }
            }
          ]
        end

        def auth_submit_label
          paired? ? "Salva" : "Avvia pairing"
        end

        def emcp_service_info
          fetch_auth_status
        end

        def fetch_auth_status
          load_credentials!
          connected = persisted? && id.present? && SessionRegistry.current.connected?(id)
          {
            authenticated: paired?,
            paired: paired?,
            connected: connected,
            pairing: pairing_token.present? && !paired?,
            qr_png_base64: (!paired? && pairing_token.present? ? Pairing.qr_png_base64(self) : nil),
            pairing_code: (!paired? ? pairing_payload_text : nil)
          }
        rescue StandardError => e
          { authenticated: false, paired: false, connected: false, pairing: false, error: e.message }
        end

        def apply_credentials(params)
          load_credentials!
          origins = Emcp.sanitize_env_value(params["browser_allowed_origins"])
          origins = credential_hash["BROWSER_ALLOWED_ORIGINS"] if origins.blank? && params["browser_allowed_origins"].nil?
          origins = OriginPolicy::DEFAULT if origins.blank?
          updates = { "BROWSER_ALLOWED_ORIGINS" => origins }
          if params.key?("browser_allow_write")
            self.allow_write = ActiveModel::Type::Boolean.new.cast(params["browser_allow_write"])
          end
          if params.key?("browser_allow_eval")
            updates["BROWSER_ALLOW_EVAL"] = flag_param(params["browser_allow_eval"])
          end
          if params.key?("browser_timeout")
            updates["BROWSER_TIMEOUT"] = number_param(params["browser_timeout"], 30)
          end
          if params.key?("browser_ws_heartbeat")
            updates["BROWSER_WS_HEARTBEAT"] = number_param(params["browser_ws_heartbeat"], 15)
          end
          unless paired?
            updates["BROWSER_PAIRING_TOKEN"] = SecureRandom.hex(32)
            updates["BROWSER_PAIRED_AT"] = nil
          end
          persist_credentials!(updates)
          true
        end

        def clear_credentials!
          SessionRegistry.current.supersede(id) if id.present?
          persist_credentials!(
            "BROWSER_PAIRING_TOKEN" => nil,
            "BROWSER_PAIRED_AT" => nil,
          )
        end

        def mark_paired!
          return if paired?

          persist_credentials!("BROWSER_PAIRED_AT" => Time.now.utc.iso8601)
        end

        def configure_tools
          define_read_tools
          define_write_tools
        end

        def replace_client!
          @client = Client.new(self)
        end

        def credential_env_keys
          %w[
            BROWSER_ALLOWED_ORIGINS BROWSER_PAIRING_TOKEN BROWSER_PAIRED_AT
            BROWSER_ALLOW_EVAL BROWSER_TIMEOUT BROWSER_WS_HEARTBEAT
          ]
        end

        def browser_flag(key)
          raw = credential_hash[key].presence || ENV[key].presence || Emcp.server_setting("browser", "allow_eval", false)
          ActiveModel::Type::Boolean.new.cast(raw)
        end

        def browser_number(key, setting, default)
          raw = credential_hash[key].presence || ENV[key].presence || Emcp.server_setting("browser", setting, default)
          seconds = raw.to_i
          seconds.positive? ? seconds : default
        end

        private

        def flag_param(value)
          ActiveModel::Type::Boolean.new.cast(value) ? "true" : "false"
        end

        def number_param(value, default)
          seconds = Emcp.sanitize_env_value(value).to_i
          (seconds.positive? ? seconds : default).to_s
        end

        def pairing_token
          credential_hash["BROWSER_PAIRING_TOKEN"].to_s
        end

        def paired?
          pairing_token.present? && credential_hash["BROWSER_PAIRED_AT"].present?
        end

        def pairing_payload_text
          payload = Pairing.payload_for(self)
          payload ? JSON.generate(payload) : nil
        end

        def relay(tool, write: false, **args)
          api_response { @client.call(tool, args, write: write) }
        end

        def define_read_tools
          define_tool(name: "browser_status", description: "Show whether the paired Chrome extension is connected.") do
            relay("browser_status")
          end

          define_tool(
            name: "browser_list_tabs",
            description: "List open tabs whose URL is on the origin allowlist.",
          ) { relay("browser_list_tabs") }

          define_tool(
            name: "browser_get_url",
            description: "Return the URL of a tab. Defaults to the active tab.",
            properties: { tab_id: integer_prop("Optional Chrome tab id") },
          ) { |tab_id: nil| relay("browser_get_url", tab_id: tab_id) }

          define_tool(
            name: "browser_get_dom",
            description: "Return HTML for a CSS selector, or the document when selector is omitted.",
            properties: {
              selector: string_prop("Optional CSS selector"),
              tab_id: integer_prop("Optional Chrome tab id"),
            },
          ) { |selector: nil, tab_id: nil| relay("browser_get_dom", selector: selector, tab_id: tab_id) }

          define_tool(
            name: "browser_get_text",
            description: "Return visible text for a CSS selector, or the page when selector is omitted.",
            properties: {
              selector: string_prop("Optional CSS selector"),
              tab_id: integer_prop("Optional Chrome tab id"),
            },
          ) { |selector: nil, tab_id: nil| relay("browser_get_text", selector: selector, tab_id: tab_id) }

          define_tool(
            name: "browser_query",
            description: "List elements matching a CSS selector (tag, text, and a short HTML snippet).",
            properties: {
              selector: string_prop("CSS selector"),
              tab_id: integer_prop("Optional Chrome tab id"),
            },
            required: ["selector"],
          ) { |selector:, tab_id: nil| relay("browser_query", selector: selector, tab_id: tab_id) }

          define_tool(
            name: "browser_read_table",
            description: "Extract HTML tables or lists as JSON rows and CSV. Useful for on-screen registries.",
            properties: {
              selector: string_prop("Optional CSS selector for one table, ul, or ol"),
              tab_id: integer_prop("Optional Chrome tab id"),
            },
          ) { |selector: nil, tab_id: nil| relay("browser_read_table", selector: selector, tab_id: tab_id) }

          define_tool(
            name: "browser_accessibility_snapshot",
            description: "Return a compact accessibility tree (role, name, text) for the page or a selector.",
            properties: {
              selector: string_prop("Optional CSS selector"),
              tab_id: integer_prop("Optional Chrome tab id"),
            },
          ) { |selector: nil, tab_id: nil| relay("browser_accessibility_snapshot", selector: selector, tab_id: tab_id) }

          define_tool(
            name: "browser_screenshot",
            description: "Capture a PNG of the visible tab and return it as a data URL.",
            properties: { tab_id: integer_prop("Optional Chrome tab id") },
          ) { |tab_id: nil| relay("browser_screenshot", tab_id: tab_id) }

          define_tool(
            name: "browser_eval_readonly",
            description: "Evaluate a JavaScript expression in the page and return a JSON value. Disabled unless Allow page JavaScript is on for this instance. The expression can still call page functions.",
            properties: {
              expression: string_prop("JavaScript expression"),
              tab_id: integer_prop("Optional Chrome tab id"),
            },
            required: ["expression"],
          ) { |expression:, tab_id: nil| relay("browser_eval_readonly", expression: expression, tab_id: tab_id) }
        end

        def define_write_tools
          define_tool(
            name: "browser_navigate",
            description: "Open a URL in a tab. The origin must be on the allowlist.",
            properties: {
              url: string_prop("Absolute http(s) URL"),
              tab_id: integer_prop("Optional tab to reuse. Omit to use the active tab."),
            },
            required: ["url"],
            write: true,
          ) { |url:, tab_id: nil| relay("browser_navigate", url: url, tab_id: tab_id, write: true) }

          define_tool(
            name: "browser_switch_tab",
            description: "Focus an existing tab by id.",
            properties: { tab_id: integer_prop("Chrome tab id from browser_list_tabs") },
            required: ["tab_id"],
            write: true,
          ) { |tab_id:| relay("browser_switch_tab", tab_id: tab_id, write: true) }

          define_tool(
            name: "browser_open_tab",
            description: "Open a new tab. The origin must be on the allowlist.",
            properties: { url: string_prop("Absolute http(s) URL") },
            required: ["url"],
            write: true,
          ) { |url:| relay("browser_open_tab", url: url, write: true) }

          define_tool(
            name: "browser_close_tab",
            description: "Close a tab by id.",
            properties: { tab_id: integer_prop("Chrome tab id") },
            required: ["tab_id"],
            write: true,
          ) { |tab_id:| relay("browser_close_tab", tab_id: tab_id, write: true) }

          define_tool(
            name: "browser_click",
            description: "Click an element matching a CSS selector.",
            properties: {
              selector: string_prop("CSS selector"),
              tab_id: integer_prop("Optional Chrome tab id"),
            },
            required: ["selector"],
            write: true,
          ) { |selector:, tab_id: nil| relay("browser_click", selector: selector, tab_id: tab_id, write: true) }

          define_tool(
            name: "browser_type",
            description: "Type text into an element. Replaces the current value and dispatches input events.",
            properties: {
              selector: string_prop("CSS selector"),
              text: string_prop("Text to insert"),
              tab_id: integer_prop("Optional Chrome tab id"),
            },
            required: %w[selector text],
            write: true,
          ) { |selector:, text:, tab_id: nil| relay("browser_type", selector: selector, text: text, tab_id: tab_id, write: true) }

          define_tool(
            name: "browser_select",
            description: "Choose an option in a select element by value or visible label.",
            properties: {
              selector: string_prop("CSS selector for the select"),
              value: string_prop("Option value or label"),
              tab_id: integer_prop("Optional Chrome tab id"),
            },
            required: %w[selector value],
            write: true,
          ) { |selector:, value:, tab_id: nil| relay("browser_select", selector: selector, value: value, tab_id: tab_id, write: true) }

          define_tool(
            name: "browser_set_value",
            description: "Set the value of an input, textarea, or contenteditable element.",
            properties: {
              selector: string_prop("CSS selector"),
              value: string_prop("New value"),
              tab_id: integer_prop("Optional Chrome tab id"),
            },
            required: %w[selector value],
            write: true,
          ) { |selector:, value:, tab_id: nil| relay("browser_set_value", selector: selector, value: value, tab_id: tab_id, write: true) }

          define_tool(
            name: "browser_check",
            description: "Check or uncheck a checkbox or radio button.",
            properties: {
              selector: string_prop("CSS selector"),
              checked: boolean_prop("Checked state. Default true."),
              tab_id: integer_prop("Optional Chrome tab id"),
            },
            required: ["selector"],
            write: true,
          ) { |selector:, checked: true, tab_id: nil| relay("browser_check", selector: selector, checked: checked, tab_id: tab_id, write: true) }

          define_tool(
            name: "browser_scroll",
            description: "Scroll the page or an element.",
            properties: {
              selector: string_prop("Optional CSS selector. Omit to scroll the window."),
              x: integer_prop("Horizontal pixels"),
              y: integer_prop("Vertical pixels"),
              tab_id: integer_prop("Optional Chrome tab id"),
            },
            write: true,
          ) { |selector: nil, x: 0, y: 0, tab_id: nil| relay("browser_scroll", selector: selector, x: x, y: y, tab_id: tab_id, write: true) }

          define_tool(
            name: "browser_wait_for",
            description: "Wait until a CSS selector matches, or until timeout.",
            properties: {
              selector: string_prop("CSS selector"),
              timeout_ms: integer_prop("Max wait in milliseconds. Default 10000."),
              tab_id: integer_prop("Optional Chrome tab id"),
            },
            required: ["selector"],
            write: true,
          ) { |selector:, timeout_ms: nil, tab_id: nil| relay("browser_wait_for", selector: selector, timeout_ms: timeout_ms, tab_id: tab_id, write: true) }

          define_tool(
            name: "browser_download",
            description: "Fetch a URL with the page session and return filename, type, size, and base64 content.",
            properties: {
              url: string_prop("Absolute URL on an allowed origin"),
              tab_id: integer_prop("Optional Chrome tab id whose cookies should be used"),
            },
            required: ["url"],
            write: true,
          ) { |url:, tab_id: nil| relay("browser_download", url: url, tab_id: tab_id, write: true) }

          define_tool(
            name: "browser_get_file",
            description: "Same as browser_download: fetch an attachment with the logged-in session.",
            properties: {
              url: string_prop("Absolute URL on an allowed origin"),
              tab_id: integer_prop("Optional Chrome tab id"),
            },
            required: ["url"],
            write: true,
          ) { |url:, tab_id: nil| relay("browser_get_file", url: url, tab_id: tab_id, write: true) }
        end
      end
    end
  end
end

Emcp.register_integration(Emcp::Servers::Browser::Server)
