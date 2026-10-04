# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require "uri"
require_relative "bridge_process"

module Emcp
  module Servers
    module Telegram
      class Client
        class Error < StandardError; end

        FLOOD_ATTEMPTS = 3
        FLOOD_SLEEP_CAP = 30

        def initialize(
          base_url: nil,
          token: nil,
          store_dir:,
          binary: nil,
          timeout: 30,
          transport: nil,
          inbound_url: nil,
          api_id: nil,
          api_hash: nil,
          phone: nil,
          session_key: nil,
          sleeper: ->(seconds) { sleep(seconds) }
        )
          @base_url = Emcp.sanitize_env_value(base_url)
          @token = Emcp.sanitize_env_value(token)
          @store_dir = store_dir.to_s
          @inbound_url = inbound_url.to_s
          @api_id = api_id.to_s
          @api_hash = api_hash.to_s
          @phone = phone.to_s
          @session_key = session_key.to_s
          @timeout = timeout.to_i.positive? ? timeout.to_i : 30
          @transport = transport
          @sleeper = sleeper
          @process = BridgeProcess.new(
            store_dir: @store_dir,
            binary: binary.presence || ENV["TELEGRAM_BRIDGE_BIN"].presence || BridgeProcess::DEFAULT_BINARY,
            token: @token,
            inbound_url: @inbound_url,
            api_id: @api_id,
            api_hash: @api_hash,
            phone: @phone,
            session_key: @session_key,
          )
        end

        def managed? = @base_url.empty?

        def credentials_ready?
          @api_id.present? && @api_hash.present? && @phone.present? && @session_key.present?
        end

        def bridge_configured? = !managed? || @process.configured?

        def reachable?
          health_url.present? && health_ok?
        end

        def session_stored?
          File.exist?(session_file)
        end

        def session_file
          @process.session_file
        end

        def unreachable_reason
          if managed? && !@process.running?
            return @process.missing_binary_message unless @process.configured?

            return "Telegram bridge is not running. Open Auth and click Start linking."
          end

          return "TELEGRAM_BRIDGE_URL is not configured" if bridge_url.blank?

          "Telegram bridge is not reachable at #{bridge_url}"
        end

        def ensure_bridge!
          if managed?
            raise Error, @process.missing_binary_message unless @process.configured?

            @process.ensure_running!
          end
          raise Error, unreachable_reason unless reachable?

          true
        end

        def restart_bridge!
          return ensure_bridge! unless managed?

          raise Error, @process.missing_binary_message unless @process.configured?

          @process.stop!
          sleep 0.3
          @process.start!
          raise Error, unreachable_reason unless reachable?

          true
        end

        def stop_bridge!
          @process.stop! if managed?
        end

        def status = get("/api/status")

        def submit_code!(code)
          post("/api/auth/code", body: { code: code })
        end

        def submit_password!(password)
          post("/api/auth/password", body: { password: password })
        end

        def logout = post("/api/logout")

        def search_contacts(query:)
          get("/api/contacts", query: { query: query })
        end

        def list_chats(query: nil, limit: nil, page: nil, sort_by: nil, type: nil)
          get("/api/chats", query: compact_query(query: query, limit: limit, page: page, sort_by: sort_by, type: type))
        end

        def get_chat(chat_id:)
          get("/api/chat", query: { chat_id: chat_id })
        end

        def list_messages(chat_id: nil, sender: nil, query: nil, after: nil, before: nil, limit: nil, page: nil)
          stamp_messages(get("/api/messages", query: compact_query(
            chat_id: chat_id, sender: sender, query: query, after: after, before: before, limit: limit, page: page,
          )))
        end

        def message_context(chat_id:, message_id:, before: nil, after: nil)
          stamp_messages(get("/api/message_context", query: compact_query(
            chat_id: chat_id, message_id: message_id, before: before, after: after,
          )))
        end

        def last_interaction(peer_id:)
          stamp_messages(get("/api/last_interaction", query: { peer_id: peer_id }))
        end

        def list_unread(limit: nil)
          stamp_messages(get("/api/unread", query: compact_query(limit: limit)))
        end

        def send_message(recipient:, message:, reply_to_message_id: nil)
          post("/api/send", body: compact_query(
            recipient: recipient, message: message, reply_to_message_id: reply_to_message_id,
          ))
        end

        private

        def health_ok?
          body = request(:get, "/health", auth: false)
          body.is_a?(Hash) && body["ok"] == true
        rescue Error, StandardError
          false
        end

        def get(path, query: {})
          request(:get, path, query: query)
        end

        def post(path, body: {})
          request(:post, path, body: body)
        end

        def request(method, path, query: {}, body: nil, auth: true)
          attempts = 0
          loop do
            result = perform(method, path, query: query, body: body, auth: auth)
            status = result[:status].to_i
            parsed = result[:body]
            return parsed if status.between?(200, 299)

            detail = error_detail(parsed)
            wait = flood_wait_seconds(status, parsed)
            if wait && attempts < FLOOD_ATTEMPTS && wait <= FLOOD_SLEEP_CAP
              attempts += 1
              @sleeper.call(wait)
              next
            end

            if wait
              raise Error, "Telegram FloodWait: retry after #{wait} seconds. #{detail}"
            end

            raise Error, "Telegram bridge #{status}: #{detail}"
          end
        end

        def perform(method, path, query:, body:, auth:)
          return @transport.call(method, path, query: query, body: body, auth: auth) if @transport

          uri = URI.join("#{bridge_url}/", path.delete_prefix("/"))
          values = compact_query(query)
          uri.query = URI.encode_www_form(values) if values.any?

          klass = method.to_sym == :post ? Net::HTTP::Post : Net::HTTP::Get
          http_request = klass.new(uri)
          http_request["Accept"] = "application/json"
          if body
            http_request["Content-Type"] = "application/json"
            http_request.body = JSON.generate(body)
          end
          http_request["X-Bridge-Token"] = @token if auth && @token.present?

          response = Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: [ @timeout, 5 ].min,
            read_timeout: @timeout,
            write_timeout: @timeout,
          ) { |http| http.request(http_request) }

          { status: response.code.to_i, body: parse_body(response.body) }
        rescue Timeout::Error, SocketError, SystemCallError, EOFError => e
          raise Error, "Telegram bridge network error: #{e.message}"
        end

        def flood_wait_seconds(status, parsed)
          return unless status == 429 && parsed.is_a?(Hash)

          seconds = parsed["flood_wait_seconds"].to_i
          seconds.positive? ? seconds : nil
        end

        def error_detail(parsed)
          return parsed["error"].presence || parsed["message"].presence || parsed.to_json if parsed.is_a?(Hash)

          parsed.to_s
        end

        def stamp_messages(payload)
          return payload unless payload.is_a?(Hash)

          %w[messages context].each do |key|
            next unless payload[key].is_a?(Array)

            payload[key].each { |row| stamp_row(row) }
          end
          stamp_row(payload["message"]) if payload["message"].is_a?(Hash)
          stamp_row(payload["last_message"]) if payload["last_message"].is_a?(Hash)
          Array(payload["chats"]).each { |row| stamp_row(row["last_message"]) if row.is_a?(Hash) }
          payload
        end

        def stamp_row(row)
          return unless row.is_a?(Hash) && row.key?("timestamp")

          row["timestamp"] = rfc3339(row["timestamp"])
        end

        def rfc3339(value)
          text = value.to_s.strip
          return nil if text.empty?

          time = if text.match?(/\A\d+\z/)
                   Time.at(text.to_i).utc
                 else
                   Time.iso8601(text).utc
                 end
          time.iso8601
        rescue ArgumentError
          text
        end

        def parse_body(raw)
          return {} if raw.blank?

          JSON.parse(raw)
        rescue JSON::ParserError
          raw.to_s
        end

        def compact_query(values)
          values.to_h.filter_map do |key, value|
            next if value.nil? || value == ""

            [ key.to_s, value ]
          end.to_h
        end

        def bridge_url
          @base_url.presence || @process.url.to_s.sub(%r{/\z}, "")
        end

        def health_url
          bridge_url.presence
        end
      end
    end
  end
end
