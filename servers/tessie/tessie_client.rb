# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "uri"

module Emcp
  module Servers
    module Tessie
      class Client
        API_BASE = "https://api.tessie.com"
        CACHE_TTL = 20
        MAX_ATTEMPTS = 3
        COMMAND_ATTEMPTS = 3

        class Error < StandardError
          attr_reader :status, :retry_after

          def initialize(message, status: nil, retryable: false, retry_after: nil)
            super(message)
            @status = status
            @retryable = retryable
            @retry_after = retry_after
          end

          def retryable? = @retryable
        end

        def initialize(token: nil, timeout: nil, transport: nil, cache: Rails.cache)
          @token_override = token
          @timeout = (timeout || ENV.fetch("TESSIE_TIMEOUT", "45")).to_i
          @timeout = 45 unless @timeout.positive?
          @transport = transport
          @cache = cache
        end

        def vehicles
          cached_get("/vehicles")
        end

        def state(vin)
          cached_get("/#{vin}/state", query: { "use_cache" => "true" })
        end

        def location(vin)
          cached_get("/#{vin}/location")
        end

        def battery(vin)
          cached_get("/#{vin}/battery")
        end

        def drives(vin, query)
          cached_get("/#{vin}/drives", query: metric_query.merge(query))
        end

        def charges(vin, query)
          cached_get("/#{vin}/charges", query: metric_query.merge(query))
        end

        def tire_pressure(vin)
          cached_get("/#{vin}/tire_pressure", query: { "pressure_format" => "bar" })
        end

        def status(vin)
          get("/#{vin}/status")
        end

        def wake(vin)
          post("/#{vin}/wake", timeout: [ @timeout, 100 ].max)
        end

        def command(vin, name, query: {})
          post(
            "/#{vin}/command/#{name}",
            query: {
              "wait_for_completion" => "true",
              "max_attempts" => COMMAND_ATTEMPTS.to_s,
            }.merge(query.transform_keys(&:to_s)),
          )
        end

        def get(path, query: {}, timeout: @timeout)
          request(:get, path, query: query, timeout: timeout)
        end

        def post(path, query: {}, timeout: @timeout)
          request(:post, path, query: query, timeout: timeout)
        end

        private

        def metric_query
          { "distance_format" => "km", "temperature_format" => "c" }
        end

        def cached_get(path, query: {})
          @cache.fetch(cache_key(path, query), expires_in: CACHE_TTL) do
            get(path, query: query)
          end
        end

        def cache_key(path, query)
          digest = Digest::SHA256.hexdigest(token)[0, 16]
          encoded = query.map { |key, value| "#{key}=#{value}" }.sort.join("&")
          "tessie/#{digest}/#{path}?#{encoded}"
        end

        def request(method, path, query: {}, timeout: @timeout)
          raise Error, "TESSIE_API_TOKEN is not configured" if token.empty?

          attempt = 0
          begin
            attempt += 1
            status, body, headers = perform(method, path, query, timeout)
            log_exchange(method, path, status)
            interpret(status, body, headers)
          rescue Error => e
            raise unless e.retryable? && attempt < MAX_ATTEMPTS

            pause(backoff(attempt, e.retry_after))
            retry
          end
        end

        def perform(method, path, query, timeout)
          return @transport.call(method, path, query, timeout) if @transport

          uri = URI.join("#{API_BASE}/", path.to_s.sub(%r{\A/+}, ""))
          values = query.to_h.reject { |_, value| value.nil? || value == "" }
          uri.query = URI.encode_www_form(values) unless values.empty?
          http_request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
          http_request["Accept"] = "application/json"
          http_request["Authorization"] = "Bearer #{token}"
          response = Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: true,
            open_timeout: timeout,
            read_timeout: timeout,
            write_timeout: timeout,
          ) { |http| http.request(http_request) }
          [ response.code.to_i, response.body.to_s, response.each_header.to_h ]
        rescue Timeout::Error, SocketError, SystemCallError => e
          log_exchange(method, path, "timeout")
          raise Error.new("Tessie timed out (#{e.class}). The vehicle may be asleep.")
        end

        def interpret(status, body, headers)
          parsed = parse_body(body)
          return parsed if status.between?(200, 299)

          detail = safe_detail(parsed)
          case status
          when 401
            raise Error.new("Tessie token was rejected (401). Check TESSIE_API_TOKEN from dash.tessie.com/settings/api.", status: 401)
          when 408
            raise Error.new("Tessie timed out (408). The vehicle may be asleep. #{detail}".strip, status: 408)
          when 429
            raise Error.new(
              "Tessie rate limit (429). #{detail}".strip,
              status: 429, retryable: true, retry_after: retry_after(headers),
            )
          when 500..599
            raise Error.new("Tessie server error (#{status}). #{detail}".strip, status: status, retryable: true)
          else
            raise Error.new("Tessie request failed (#{status}). #{detail}".strip, status: status)
          end
        end

        def parse_body(body)
          return {} if body.to_s.strip.empty?

          JSON.parse(body)
        rescue JSON::ParserError
          body.to_s
        end

        def safe_detail(parsed)
          text = parsed.is_a?(String) ? parsed : JSON.generate(parsed)
          text = text.gsub(/Bearer\s+\S+/i, "Bearer [redacted]")
          text = text.gsub(token, "[redacted]") if token.present?
          text.strip[0, 180]
        end

        def retry_after(headers)
          value = headers.to_h.find { |key, _| key.to_s.casecmp("retry-after").zero? }&.last
          return if value.nil? || value.to_s.strip.empty?

          seconds = value.to_f
          seconds.positive? ? seconds : nil
        end

        def backoff(attempt, retry_after)
          hinted = retry_after.to_f
          return hinted.clamp(0.2, 8) if hinted.positive?

          (0.4 * (2**(attempt - 1))).clamp(0.2, 8)
        end

        def pause(seconds)
          sleep seconds
        end

        def log_exchange(method, path, status)
          Rails.logger.info("[tessie] #{method.to_s.upcase} #{path} #{status}")
        end

        def token
          Emcp.sanitize_env_value(@token_override.nil? ? ENV["TESSIE_API_TOKEN"] : @token_override)
        end
      end
    end
  end
end
