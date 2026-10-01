# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module Emcp
  module Servers
    module Shopify
      class Client
        API_VERSION = "2026-07"
        SAFE_RESPONSE_HEADERS = %w[
          content-type cache-control date retry-after
          x-request-id
        ].freeze

        class Error < StandardError; end

        def initialize(
          token: nil,
          timeout: ENV.fetch("SHOPIFY_TIMEOUT", "30").to_i,
          max_chars: ENV.fetch("EMCP_MAX_CHARS", "12000").to_i,
          on_token_refresh: nil
        )
          @token_override = token
          @timeout = timeout.positive? ? timeout : 30
          @max_chars = max_chars.positive? ? max_chars : 12_000
          @on_token_refresh = on_token_refresh
          @refresh_mutex = Mutex.new
        end

        def graphql(query, variables: nil)
          body = { query: query }
          body[:variables] = variables if variables
          result = post_json(admin_graphql_uri, body, headers: { "X-Shopify-Access-Token" => access_token })
          if result[:status] == 401 && refresh_access_token!
            result = post_json(admin_graphql_uri, body, headers: { "X-Shopify-Access-Token" => access_token })
          end
          raise Error, "Shopify Admin API #{result[:status]}: #{error_detail(result)}" unless result[:status].between?(200, 299)

          result
        end

        def exchange_authorization_code(code:)
          body = token_form(
            client_id: client_id,
            client_secret: client_secret,
            code: code,
            expiring: "1",
          )
          raise Error, "Shopify rejected the authorization code" unless body

          { status: 200, body: body }
        end

        def refresh_access_token!
          @refresh_mutex.synchronize do
            refresh = Emcp.sanitize_env_value(ENV["SHOPIFY_REFRESH_TOKEN"])
            return false if refresh.empty?

            body = token_form(
              client_id: client_id,
              client_secret: client_secret,
              grant_type: "refresh_token",
              refresh_token: refresh,
            )
            return false unless body

            access = Emcp.sanitize_env_value(body["access_token"])
            return false if access.empty?

            new_refresh = Emcp.sanitize_env_value(body["refresh_token"])
            new_refresh = refresh if new_refresh.empty?
            ENV["SHOPIFY_TOKEN"] = access
            ENV["SHOPIFY_REFRESH_TOKEN"] = new_refresh
            @on_token_refresh&.call(access_token: access, refresh_token: new_refresh, body: body)
            true
          end
        rescue Error
          false
        end

        def self.shop_domain(value = ENV["SHOPIFY_SHOP"])
          shop = Emcp.sanitize_env_value(value).downcase.sub(%r{\Ahttps?://}, "").sub(%r{/.*\z}, "")
          shop = "#{shop}.myshopify.com" unless shop.include?(".")
          unless shop.match?(/\A[a-z0-9][a-z0-9-]*\.myshopify\.com\z/)
            raise Error, "SHOPIFY_SHOP must be a *.myshopify.com domain"
          end

          shop
        end

        def self.authorization_url(callback_url:, state:, scopes:)
          query = {
            client_id: Emcp.sanitize_env_value(ENV["SHOPIFY_CLIENT_ID"]),
            scope: scopes,
            redirect_uri: callback_url,
            state: state,
          }
          "https://#{shop_domain}/admin/oauth/authorize?#{URI.encode_www_form(query)}"
        end

        def self.valid_hmac?(params, secret:)
          hmac = params["hmac"].to_s
          return false if hmac.empty? || secret.to_s.empty?

          message = params.except("hmac").sort.map { |key, value| "#{key}=#{value}" }.join("&")
          digest = OpenSSL::HMAC.hexdigest("SHA256", secret, message)
          ActiveSupport::SecurityUtils.secure_compare(digest, hmac)
        end

        private

        def admin_graphql_uri
          version = Emcp.sanitize_env_value(ENV["SHOPIFY_API_VERSION"])
          version = API_VERSION if version.empty?
          URI("https://#{self.class.shop_domain}/admin/api/#{version}/graphql.json")
        end

        def token_form(form)
          uri = URI("https://#{self.class.shop_domain}/admin/oauth/access_token")
          request = Net::HTTP::Post.new(uri)
          request["Accept"] = "application/json"
          request["Content-Type"] = "application/x-www-form-urlencoded"
          request.body = URI.encode_www_form(form)
          response = perform(uri, request)
          return nil unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body.to_s)
        rescue JSON::ParserError
          nil
        end

        def post_json(uri, body, headers:)
          token = access_token
          raise Error, "Shopify access token is not configured" if headers["X-Shopify-Access-Token"].to_s.empty? && token.empty?

          request = Net::HTTP::Post.new(uri)
          request["Accept"] = "application/json"
          request["Content-Type"] = "application/json"
          headers.each { |key, value| request[key] = value }
          request.body = JSON.generate(body)
          response_result(perform(uri, request))
        rescue Timeout::Error, SocketError, SystemCallError => e
          raise Error, "Shopify request failed: #{e.message}"
        end

        def perform(uri, request)
          Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: true,
            open_timeout: @timeout,
            read_timeout: @timeout,
            write_timeout: @timeout,
          ) { |http| http.request(request) }
        end

        def access_token
          raw = @token_override.nil? ? ENV["SHOPIFY_TOKEN"] : @token_override
          Emcp.sanitize_env_value(raw)
        end

        def client_id
          id = Emcp.sanitize_env_value(ENV["SHOPIFY_CLIENT_ID"])
          raise Error, "SHOPIFY_CLIENT_ID is required" if id.empty?

          id
        end

        def client_secret
          secret = Emcp.sanitize_env_value(ENV["SHOPIFY_CLIENT_SECRET"])
          raise Error, "SHOPIFY_CLIENT_SECRET is required" if secret.empty?

          secret
        end

        def response_result(response)
          raw = response.body.to_s
          truncated = raw.length > @max_chars
          output = truncated ? "#{raw[0, @max_chars]}\n...[truncated]" : raw
          parsed = truncated || output.empty? ? output.presence : JSON.parse(output)
          {
            status: response.code.to_i,
            headers: response.each_header.to_h.slice(*SAFE_RESPONSE_HEADERS),
            body: parsed,
          }
        rescue JSON::ParserError
          { status: response.code.to_i, headers: response.each_header.to_h.slice(*SAFE_RESPONSE_HEADERS), body: output }
        end

        def error_detail(result)
          result[:body].is_a?(String) ? result[:body] : JSON.generate(result[:body])
        end
      end
    end
  end
end
