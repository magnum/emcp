# frozen_string_literal: true

require_relative "generic_client"

module Emcp
  module Servers
    module Generic
      class Server < ::McpServer
        server_id "generic"
        display_name "Generic"
        description "Proxy any remote MCP server into a context, with a token sent as a header or query parameter."
        version "0.1.0"
        ord(-1)

        TOOL_CACHE_TTL = 60

        def instructions
          "This server forwards a remote MCP endpoint into EmCP so a Context can proxy it. " \
            "Authentication is a token or API key, sent either as an HTTP header or a query parameter. " \
            "The header named Authorization is sent as Bearer. Any other header name sends the raw token. " \
            "Remote tools stay disabled until allow_write is on for this instance, " \
            "because a generic proxy cannot tell which remote tools only read. " \
            "Point the URL at the remote MCP endpoint, for example https://wrks.it/mcp."
        end

        def auth_help_content
          {
            title: "Connect a remote MCP",
            description: "EmCP calls the remote MCP over HTTP and publishes its tools on this instance. Add the instance to a Context when several servers should share one connector.",
            steps: [
              "Paste the remote MCP URL, such as https://wrks.it/mcp.",
              "Leave authentication on Token / API key.",
              "Choose header or query string, then the key name. Blank uses Authorization for a header and api_key for a query string.",
              "Paste the token. Leave it blank later to keep the saved one.",
              "Turn on Allow write to forward the remote tools. Leave it off to keep them disabled.",
            ],
            note: "The token is stored with this instance. A header named Authorization is sent as Bearer token. Other header names send the token unchanged.",
          }
        end

        def auth_fields
          [
            {
              name: "generic_url",
              label: "MCP URL",
              type: "text",
              required: true,
              help: "Remote MCP endpoint. Example: https://wrks.it/mcp",
              env: "GENERIC_URL",
            },
            {
              name: "generic_auth_type",
              label: "Authentication",
              type: "select",
              required: true,
              options: [ [ "Token / API key", "token" ] ],
              default: "token",
              help: "Only token or API key is available.",
              env: "GENERIC_AUTH_TYPE",
            },
            {
              name: "generic_token_in",
              label: "Send token",
              type: "select",
              required: true,
              options: [ [ "Header", "header" ], [ "Query string", "query" ] ],
              default: "header",
              help: "Where the remote server expects the token.",
              env: "GENERIC_TOKEN_IN",
            },
            {
              name: "generic_token_key",
              label: "Token key",
              type: "text",
              required: false,
              help: "Header name or query parameter. Blank uses Authorization for a header and api_key for a query string.",
              env: "GENERIC_TOKEN_KEY",
            },
            {
              name: "generic_token",
              label: "Token",
              type: "password",
              required: true,
              help: "API key or bearer token. Leave blank to keep the saved token.",
              env: "GENERIC_TOKEN",
            },
            {
              name: "generic_allow_write",
              label: "Allow write",
              type: "checkbox",
              help: "Forward the remote tools. They stay disabled until this is on.",
              value: -> { allow_write? ? "true" : "false" },
            },
          ]
        end

        def auth_status_cache_ttl = 30

        def emcp_service_info
          fetch_auth_status
        end

        def fetch_auth_status
          load_credentials!
          status = @client.status
          {
            authenticated: true,
            url: public_endpoint,
            auth_type: "token",
            token_in: stored("GENERIC_TOKEN_IN").presence || "header",
            token_key: stored("GENERIC_TOKEN_KEY").presence,
            tools: status["tools"],
            server: status["server"],
          }.compact
        rescue StandardError => e
          { authenticated: false, url: public_endpoint.presence, error: e.message }.compact
        end

        def apply_credentials(params)
          load_credentials!
          token = Emcp.sanitize_env_value(params["generic_token"])
          updates = {}
          assign_update(updates, "GENERIC_URL", params["generic_url"])
          assign_update(updates, "GENERIC_AUTH_TYPE", params["generic_auth_type"])
          assign_update(updates, "GENERIC_TOKEN_IN", params["generic_token_in"])
          if params.key?("generic_token_key")
            updates["GENERIC_TOKEN_KEY"] = Emcp.sanitize_env_value(params["generic_token_key"])
          end
          updates["GENERIC_TOKEN"] = token if token.present?

          effective_url = updates["GENERIC_URL"].presence || stored("GENERIC_URL")
          effective_token = updates["GENERIC_TOKEN"].presence || stored("GENERIC_TOKEN")
          raise "MCP URL is required" if effective_url.empty?
          raise "Token is required" if effective_token.empty?

          apply_credentials_probe!(updates, rejection_message: "The remote MCP server rejected the token")
          if params.key?("generic_allow_write")
            update!(allow_write: ActiveModel::Type::Boolean.new.cast(params["generic_allow_write"]))
          end
          true
        ensure
          token = nil
        end

        def clear_credentials!
          persist_credentials!(
            "GENERIC_URL" => nil,
            "GENERIC_AUTH_TYPE" => nil,
            "GENERIC_TOKEN_IN" => nil,
            "GENERIC_TOKEN_KEY" => nil,
            "GENERIC_TOKEN" => nil,
          )
          replace_client!
        end

        def configure_tools
          @client.tools.each { |tool| define_remote_tool(tool) }
        rescue Client::Error
          nil
        end

        def replace_client!
          @client = Client.new
          @configured = false
          @tools = []
          @mcp_protocol_server = nil
          @tools_loaded_at = nil
        end

        def credential_env_keys = %w[GENERIC_URL GENERIC_AUTH_TYPE GENERIC_TOKEN_IN GENERIC_TOKEN_KEY GENERIC_TOKEN]

        private

        def configure_once!
          if @configured && @tools_loaded_at && Time.now - @tools_loaded_at < TOOL_CACHE_TTL
            return
          end

          @tools = []
          @resources = []
          @configured = false
          @mcp_protocol_server = nil
          super
          @tools_loaded_at = Time.now
        end

        def define_remote_tool(tool)
          name = tool["name"].to_s
          return if name.blank? || name == "emcp_service_info"
          return if tools.any? { |defined| defined.name == name }

          schema = tool["inputSchema"].is_a?(Hash) ? tool["inputSchema"] : { "type" => "object", "properties" => {} }
          define_tool(
            name: name,
            description: tool["description"].presence || "Remote MCP tool #{name}.",
            input_schema: schema,
            write: true,
          ) { |**arguments| forward_tool(name, arguments) }
        end

        def invoke_logged_tool(definition, arguments)
          return super if definition.name == "emcp_service_info"

          error = nil
          result = begin
            forward_tool(definition.name, arguments)
          rescue StandardError => e
            error = e
            nil
          end
          log_tool_activity(definition.name, arguments, result: result, error: error)
          raise error if error

          result
        end

        def forward_tool(name, arguments)
          payload = arguments.to_h.deep_stringify_keys
          body = @client.call_tool(name, payload)
          content = body.is_a?(Hash) ? body["content"] : nil
          if content.is_a?(Array)
            MCP::Tool::Response.new(
              content.map { |item| item.is_a?(Hash) ? item.deep_symbolize_keys : item },
              error: body["isError"] == true,
              structured_content: body["structuredContent"],
            )
          else
            api_response(body)
          end
        end

        def assign_update(updates, key, value)
          cleaned = Emcp.sanitize_env_value(value)
          updates[key] = cleaned if cleaned.present?
        end

        def stored(key)
          Emcp.sanitize_env_value(ENV[key])
        end

        def public_endpoint
          text = stored("GENERIC_URL")
          return if text.blank?

          uri = URI(text)
          return if uri.user
          uri.query = nil
          uri.fragment = nil
          uri.to_s
        rescue URI::InvalidURIError
          nil
        end
      end
    end
  end
end

Emcp.register_integration(Emcp::Servers::Generic::Server)
