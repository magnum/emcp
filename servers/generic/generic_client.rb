# frozen_string_literal: true

require "cgi"
require "uri"

module Emcp
  module Servers
    module Generic
      class Client
        class Error < StandardError; end

        AUTH_TYPES = %w[token].freeze
        TOKEN_LOCATIONS = %w[header query].freeze

        def initialize(session_factory: nil, url: nil, token: nil, auth_type: nil, token_in: nil, token_key: nil, timeout: nil)
          @session_factory = session_factory
          @url = url
          @token = token
          @auth_type = auth_type
          @token_in = token_in
          @token_key = token_key
          @timeout = timeout
        end

        def status
          raise Error, "MCP URL is not configured" if endpoint.blank?
          raise Error, "Token is not configured" if secret.blank?

          with_session do |session|
            listed = normalize_tools(session.tools)
            { "tools" => listed.size, "server" => server_name(session.respond_to?(:server_info) ? session.server_info : nil) }
          end
        end

        def tools
          return [] unless ready?

          with_session { |session| normalize_tools(session.tools) }
        end

        def call_tool(name, arguments)
          raise Error, "MCP URL is not configured" if endpoint.blank?
          raise Error, "Token is not configured" if secret.blank?

          with_session do |session|
            response = session.call_tool(name: name, arguments: arguments)
            body = response.is_a?(Hash) ? (response["result"] || response) : response
            body.is_a?(Hash) ? body : { "content" => [ { "type" => "text", "text" => body.to_s } ] }
          end
        end

        private

        def ready?
          endpoint.present? && secret.present?
        end

        def with_session
          session = open_session
          yield session
        rescue Error
          raise
        rescue StandardError => e
          raise Error, redact(e.message)
        ensure
          close_session(session)
        end

        def open_session
          options = request_options
          return @session_factory.call(options) if @session_factory

          transport = MCP::Client::HTTP.new(url: options[:url], headers: options[:headers]) do |faraday|
            faraday.options.open_timeout = timeout_seconds
            faraday.options.timeout = timeout_seconds
          end
          session = MCP::Client.new(transport: transport)
          session.connect(client_info: { name: "EmCP", version: Emcp::VERSION })
          session
        end

        def request_options
          check_auth_type!
          uri = parsed_endpoint
          headers = { "User-Agent" => "EmCP" }
          token = secret
          if token.present?
            key = token_key
            if token_in == "query"
              uri.query = [ uri.query.presence, "#{CGI.escape(key)}=#{CGI.escape(token)}" ].compact.join("&")
            else
              headers[key] = header_value(key, token)
            end
          end
          { url: uri.to_s, headers: headers }
        end

        def parsed_endpoint
          text = endpoint
          raise Error, "MCP URL is not configured" if text.blank?

          uri = URI(text)
          unless %w[http https].include?(uri.scheme) && uri.host.present?
            raise Error, "MCP URL must be an http or https URL"
          end
          raise Error, "Put the token in the token field, not in the URL" if uri.user.present?

          uri
        end

        def check_auth_type!
          return if auth_type == "token"

          raise Error, "Authentication type must be token"
        end

        def header_value(key, token)
          raise Error, "Token contains invalid characters" if token.match?(/[\r\n]/)
          return token unless key.casecmp("authorization").zero?
          return token if token.match?(/\ABearer\s+\S/i)

          "Bearer #{token}"
        end

        def endpoint
          raw(@url, "GENERIC_URL")
        end

        def secret
          raw(@token, "GENERIC_TOKEN")
        end

        def auth_type
          value = raw(@auth_type, "GENERIC_AUTH_TYPE").downcase
          value.presence || "token"
        end

        def token_in
          value = raw(@token_in, "GENERIC_TOKEN_IN").downcase
          value = "header" if value.blank?
          raise Error, "Token location must be header or query" unless TOKEN_LOCATIONS.include?(value)

          value
        end

        def token_key
          value = raw(@token_key, "GENERIC_TOKEN_KEY")
          value = token_in == "query" ? "api_key" : "Authorization" if value.blank?
          unless value.match?(/\A[A-Za-z0-9_.-]{1,64}\z/)
            raise Error, "Token key must be letters, numbers, dot, underscore, or hyphen"
          end

          value
        end

        def raw(override, env_key)
          Emcp.sanitize_env_value(override.nil? ? ENV[env_key] : override)
        end

        def normalize_tools(list)
          Array(list).filter_map do |tool|
            if tool.is_a?(Hash)
              name = tool["name"].to_s
              next if name.blank?

              schema = tool["inputSchema"]
              schema = { "type" => "object", "properties" => {} } unless schema.is_a?(Hash)
              { "name" => name, "description" => tool["description"].to_s, "inputSchema" => schema }
            elsif tool.respond_to?(:name)
              name = tool.name.to_s
              next if name.blank?

              schema = tool.respond_to?(:input_schema) ? tool.input_schema : nil
              schema = { "type" => "object", "properties" => {} } unless schema.is_a?(Hash)
              { "name" => name, "description" => tool.description.to_s, "inputSchema" => schema }
            end
          end
        end

        def server_name(info)
          return if info.blank?

          data = info.respond_to?(:deep_stringify_keys) ? info.deep_stringify_keys : info.to_h
          data.dig("serverInfo", "name")
        end

        def close_session(session)
          return unless session

          if session.respond_to?(:close)
            session.close
          elsif session.respond_to?(:transport) && session.transport.respond_to?(:close)
            session.transport.close
          end
        end

        def redact(message)
          text = message.to_s
          token = secret
          return text if token.blank?

          text.gsub(token, "[redacted]").gsub(CGI.escape(token), "[redacted]")
        end

        def timeout_seconds
          value = @timeout || Integer(ENV.fetch("GENERIC_TIMEOUT", "30"), exception: false)
          value.to_i.positive? ? value.to_i : 30
        end
      end
    end
  end
end
