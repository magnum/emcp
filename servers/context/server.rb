# frozen_string_literal: true

module Emcp
  module Servers
    module Context
      class Server < ::McpServer
        server_id "context"
        display_name "Context"
        description "A single MCP endpoint that proxies a bundle of your other servers " \
                    "(house, work, a project). Configure one connector instead of many."
        version "0.1.0"

        def instructions
          "This Context MCP is a hub. It does not talk to a third-party API; it forwards " \
            "to the EmCP servers you attached (HEY, Home Assistant, TeslaMate, …). " \
            "Workflow: context_list_servers → context_get_server / context_list_tools → " \
            "context_call_tool. Identify a proxied server by id, instance id (hey-12), " \
            "or type code when it is unique in this context. Inactive contexts and " \
            "paused memberships refuse tool calls."
        end

        def auth_help_content
          {
            title: "Context has no provider login",
            description: "MCP clients authenticate to this Context with the usual EmCP OAuth. " \
                         "Attach the servers this hub should proxy from the Context page.",
            steps: [
              "Open the Context page and add the MCP servers for this bundle (house, work, …).",
              "Pause a membership to keep it listed without exposing its tools.",
              "Point Claude / ChatGPT at this Context MCP URL only.",
            ],
            note: "Each proxied server still keeps its own credentials. This hub only forwards calls.",
          }
        end

        def issuer_url
          "#{Emcp.public_url}/context/#{id}"
        end

        def emcp_service_info
          fetch_auth_status
        end

        def fetch_auth_status
          {
            authenticated: true,
            kind: "context",
            active: active?,
            proxied: context_memberships.count,
            proxied_active: context_memberships.active.count,
          }
        end

        def apply_credentials(_params) = true
        def clear_credentials! = true
        def replace_client!
          @client = :context
        end
        def credential_env_keys = []

        def available_proxied_servers
          user.mcp_servers.proxyable.where.not(id: proxied_server_ids).includes(:mcp_server_type).order(:name)
        end

        def configure_tools
          define_tool(
            name: "context_list_servers",
            description: "List MCP servers proxied by this context (id, auth, active, name).",
          ) { api_response { list_proxied_servers } }

          define_tool(
            name: "context_get_server",
            description: "Details for one proxied MCP: auth/noauth, active, name, tools count.",
            properties: { server: string_prop("Proxied server id, instance id (hey-12), or type code") },
            required: %w[server],
          ) { |server:| api_response { proxied_details(server) } }

          define_tool(
            name: "context_list_tools",
            description: "List tools exposed by one proxied MCP server.",
            properties: { server: string_prop("Proxied server id, instance id (hey-12), or type code") },
            required: %w[server],
          ) { |server:| api_response { proxied_tools(server) } }

          define_tool(
            name: "context_call_tool",
            description: "Run a tool on a proxied MCP. Pass the child tool name and its arguments.",
            properties: {
              server: string_prop("Proxied server id, instance id (hey-12), or type code"),
              tool: string_prop("Tool name on the proxied server"),
              arguments: object_prop("Arguments object for the proxied tool"),
            },
            required: %w[server tool],
          ) { |server:, tool:, arguments: {}| call_proxied_tool(server, tool, arguments) }
        end

        def list_proxied_servers
          context_memberships.includes(mcp_server: :mcp_server_type).order(:id).map(&:proxied_snapshot)
        end

        def proxied_details(ref)
          membership = find_membership!(ref)
          membership.proxied_snapshot.merge(
            tool_count: membership.mcp_server.tool_catalog.size,
            context_active: active?,
          )
        end

        def proxied_tools(ref)
          membership = find_membership!(ref)
          {
            server: membership.proxied_snapshot,
            tools: membership.mcp_server.tool_catalog,
          }
        end

        def call_proxied_tool(ref, tool_name, arguments)
          raise "context is inactive" unless active?

          membership = find_membership!(ref)
          raise "server #{membership.mcp_server.activity_log_code} is paused in this context" unless membership.active?

          child = membership.mcp_server
          catalog = child.tool_catalog
          definition = catalog.find { |entry| entry[:name].to_s == tool_name.to_s }
          raise KeyError, "unknown tool: #{tool_name}" unless definition
          if definition[:write] && !allow_write_methods?
            raise SecurityError, "write method disabled on this context"
          end

          child.call_tool(tool_name.to_s, parse_tool_arguments(arguments))
        end

        def find_membership!(ref)
          key = ref.to_s.strip
          raise KeyError, "server is required" if key.empty?

          memberships = context_memberships.includes(mcp_server: :mcp_server_type).to_a
          matches = memberships.select { |row| membership_ref?(row, key) }
          if matches.size > 1
            ids = matches.map { |row| row.mcp_server.activity_log_code }.join(", ")
            raise KeyError, "ambiguous server #{key.inspect}; use id or instance (#{ids})"
          end
          matches.first || raise(KeyError, "unknown proxied server: #{key}")
        end

        private

        def membership_ref?(row, key)
          server = row.mcp_server
          server.id.to_s == key ||
            server.activity_log_code == key ||
            server.code.to_s == key ||
            server.name.to_s.casecmp?(key)
        end

        def parse_tool_arguments(arguments)
          case arguments
          when nil then {}
          when Hash then arguments
          when String
            parsed = JSON.parse(arguments)
            parsed.is_a?(Hash) ? parsed : {}
          else
            arguments.respond_to?(:to_h) ? arguments.to_h : {}
          end
        rescue JSON::ParserError
          {}
        end
      end
    end
  end
end

Emcp.register_integration(Emcp::Servers::Context::Server)
