# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Emcp
  module Servers
    module MicrosoftGraph
      class Client
        GRAPH_BASE = "https://graph.microsoft.com/v1.0"
        LOGIN_HOST = "login.microsoftonline.com"
        SAFE_RESPONSE_HEADERS = %w[
          content-type cache-control date request-id client-request-id
          retry-after location
        ].freeze

        class Error < StandardError; end

        def initialize(
          token: nil,
          timeout: ENV.fetch("MICROSOFTGRAPH_TIMEOUT", "30").to_i,
          max_chars: ENV.fetch("EMCP_MAX_CHARS", "12000").to_i,
          on_token_refresh: nil
        )
          @token_override = token
          @timeout = timeout.positive? ? timeout : 30
          @max_chars = max_chars.positive? ? max_chars : 12_000
          @on_token_refresh = on_token_refresh
          @refresh_mutex = Mutex.new
        end

        def get(path, query: {}) = request(:get, path, query: query)
        def post(path, body:, query: {}) = request(:post, path, query: query, body: body)
        def patch(path, body:, query: {}) = request(:patch, path, query: query, body: body)
        def put(path, body:, query: {}) = request(:put, path, query: query, body: body)
        def delete(path, query: {}) = request(:delete, path, query: query)

        def request(method, path, query: {}, body: nil, raise_on_error: true, retrying: false)
          token = access_token
          raise Error, "Microsoft Graph access token is not configured" if token.empty?
          raise Error, "request body must be a JSON object" if body && !body.is_a?(Hash)

          uri = graph_uri(path, query)
          request_class = {
            get: Net::HTTP::Get,
            post: Net::HTTP::Post,
            put: Net::HTTP::Put,
            patch: Net::HTTP::Patch,
            delete: Net::HTTP::Delete,
          }.fetch(method.to_sym)
          http_request = request_class.new(uri)
          http_request["Accept"] = "application/json"
          http_request["Authorization"] = "Bearer #{token}"
          if body
            http_request["Content-Type"] = "application/json"
            http_request.body = JSON.generate(body)
          end

          response = perform(uri, http_request)
          if response.code.to_i == 401 && !retrying && refresh_access_token!
            return request(method, path, query: query, body: body, raise_on_error: raise_on_error, retrying: true)
          end

          result = response_result(response)
          if raise_on_error && !response.is_a?(Net::HTTPSuccess)
            detail = result[:body].is_a?(String) ? result[:body] : JSON.generate(result[:body])
            raise Error, "Microsoft Graph API #{result[:status]}: #{detail}"
          end
          result
        rescue Timeout::Error, SocketError, SystemCallError => e
          raise Error, "Microsoft Graph request failed: #{e.message}"
        end

        def refresh_access_token!
          @refresh_mutex.synchronize do
            refresh = Emcp.sanitize_env_value(ENV["MICROSOFTGRAPH_REFRESH_TOKEN"])
            return false if refresh.empty?

            client_id = Emcp.sanitize_env_value(ENV["MICROSOFTGRAPH_CLIENT_ID"])
            client_secret = Emcp.sanitize_env_value(ENV["MICROSOFTGRAPH_CLIENT_SECRET"])
            return false if client_id.empty? || client_secret.empty?

            body = token_request(
              grant_type: "refresh_token",
              client_id: client_id,
              client_secret: client_secret,
              refresh_token: refresh,
              scope: Emcp.sanitize_env_value(ENV["MICROSOFTGRAPH_OAUTH_SCOPES"]),
            )
            return false unless body

            access = Emcp.sanitize_env_value(body["access_token"])
            return false if access.empty?

            new_refresh = Emcp.sanitize_env_value(body["refresh_token"])
            new_refresh = refresh if new_refresh.empty?
            ENV["MICROSOFTGRAPH_TOKEN"] = access
            ENV["MICROSOFTGRAPH_REFRESH_TOKEN"] = new_refresh
            @on_token_refresh&.call(access_token: access, refresh_token: new_refresh, body: body)
            true
          end
        rescue Error
          false
        end

        def exchange_authorization_code(callback_url:, code:)
          client_id = Emcp.sanitize_env_value(ENV["MICROSOFTGRAPH_CLIENT_ID"])
          client_secret = Emcp.sanitize_env_value(ENV["MICROSOFTGRAPH_CLIENT_SECRET"])
          raise Error, "MICROSOFTGRAPH_CLIENT_ID is required" if client_id.empty?
          raise Error, "MICROSOFTGRAPH_CLIENT_SECRET is required" if client_secret.empty?

          body = token_request(
            grant_type: "authorization_code",
            client_id: client_id,
            client_secret: client_secret,
            code: code,
            redirect_uri: callback_url,
            scope: Emcp.sanitize_env_value(ENV["MICROSOFTGRAPH_OAUTH_SCOPES"]),
          )
          raise Error, "Microsoft identity platform rejected the authorization code" unless body

          { status: 200, body: body }
        end

        def self.tenant_id
          raw = Emcp.sanitize_env_value(ENV["MICROSOFTGRAPH_TENANT_ID"])
          tenant = raw.empty? ? "organizations" : raw
          unless tenant.match?(/\A[A-Za-z0-9][A-Za-z0-9.-]{0,127}\z/)
            raise Error, "MICROSOFTGRAPH_TENANT_ID is not a valid tenant"
          end

          tenant
        end

        def self.authorization_url(callback_url:, state:, scopes:)
          query = {
            client_id: Emcp.sanitize_env_value(ENV["MICROSOFTGRAPH_CLIENT_ID"]),
            response_type: "code",
            redirect_uri: callback_url,
            response_mode: "query",
            scope: scopes,
            state: state,
          }
          "https://#{LOGIN_HOST}/#{tenant_id}/oauth2/v2.0/authorize?#{URI.encode_www_form(query)}"
        end

        private

        def graph_uri(path, query)
          relative = path.to_s.strip
          raise Error, "Graph path must start with /" unless relative.start_with?("/")
          raise Error, "Graph path must stay on graph.microsoft.com/v1.0" if relative.include?("://") || relative.include?("..")

          uri = URI.join("#{GRAPH_BASE}/", relative.delete_prefix("/"))
          raise Error, "Graph path must stay on graph.microsoft.com" unless uri.host == "graph.microsoft.com"

          values = query.to_h.reject { |_, value| value.nil? || value == "" }
          uri.query = URI.encode_www_form(values) unless values.empty?
          uri
        end

        def token_request(form)
          tenant = self.class.tenant_id
          uri = URI("https://#{LOGIN_HOST}/#{tenant}/oauth2/v2.0/token")
          http_request = Net::HTTP::Post.new(uri)
          http_request["Accept"] = "application/json"
          http_request["Content-Type"] = "application/x-www-form-urlencoded"
          fields = form.reject { |_, value| value.nil? || value.to_s.empty? }
          http_request.body = URI.encode_www_form(fields)
          response = perform(uri, http_request)
          return nil unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body.to_s)
        rescue JSON::ParserError
          nil
        end

        def perform(uri, http_request)
          Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: true,
            open_timeout: @timeout,
            read_timeout: @timeout,
            write_timeout: @timeout,
          ) { |http| http.request(http_request) }
        end

        def access_token
          raw = @token_override.nil? ? ENV["MICROSOFTGRAPH_TOKEN"] : @token_override
          Emcp.sanitize_env_value(raw)
        end

        def response_result(response)
          raw = response.body.to_s
          truncated = raw.length > @max_chars
          output = truncated ? "#{raw[0, @max_chars]}\n...[truncated]" : raw
          parsed = if truncated || output.empty?
                     output.presence
                   else
                     JSON.parse(output)
                   end
          {
            status: response.code.to_i,
            headers: response.each_header.to_h.slice(*SAFE_RESPONSE_HEADERS),
            body: parsed,
          }
        rescue JSON::ParserError
          {
            status: response.code.to_i,
            headers: response.each_header.to_h.slice(*SAFE_RESPONSE_HEADERS),
            body: output,
          }
        end
      end
    end
  end
end
