# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "bridge_process"

module Emcp
  module Servers
    module Whatsapp
      class Client
        class Error < StandardError; end

        DEFAULT_BINARY = BridgeProcess::DEFAULT_BINARY

        def initialize(base_url: nil, token: nil, store_dir:, binary: nil, timeout: 30, transport: nil)
          @base_url = Emcp.sanitize_env_value(base_url)
          @token = Emcp.sanitize_env_value(token)
          @store_dir = store_dir.to_s
          @timeout = timeout.to_i.positive? ? timeout.to_i : 30
          @transport = transport
          @process = BridgeProcess.new(
            store_dir: @store_dir,
            binary: binary.presence || ENV["WHATSAPP_BRIDGE_BIN"].presence || DEFAULT_BINARY,
            token: @token,
          )
        end

        def managed?
          @base_url.empty?
        end

        def reachable?
          health_url.present? && health_ok?
        end

        def unreachable_reason
          if managed? && !@process.running?
            if @process.configured?
              return "WhatsApp bridge is not running. Open Auth and click Start pairing to connect an account."
            end

            return @process.missing_binary_message
          end

          return "WHATSAPP_BRIDGE_URL is not configured" if bridge_url.blank?

          "WhatsApp bridge is not reachable at #{bridge_url}"
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
          return unless managed?
          raise Error, @process.missing_binary_message unless @process.configured?

          @process.stop!
          sleep 0.3
          @process.start!
          raise Error, unreachable_reason unless reachable?

          true
        end

        def wait_for_pairing_code!(timeout: 25)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_i
          loop do
            body = status
            return body if pairing_code?(body) || truthy?(body["logged_in"])

            detail = body["error"].to_s.strip
            raise Error, detail if detail.present? && (!truthy?(body["pairing"]) || pairing_failed?(detail))

            if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
              raise Error, [ detail.presence, "Timed out waiting for a WhatsApp QR code. Check #{@process.log_file}." ].compact.join(" ")
            end

            sleep 0.4
          end
        end

        def stop_bridge!
          @process.stop! if managed?
        end

        def status
          get("/api/status")
        end

        def logout
          post("/api/logout")
        end

        def send_message(recipient:, message:)
          post("/api/send", body: { recipient: recipient, message: message })
        end

        def search_contacts(query:)
          get("/api/contacts", query: { query: query })
        end

        def list_chats(query: nil, limit: nil, page: nil, sort_by: nil)
          get("/api/chats", query: compact_query({ query: query, limit: limit, page: page, sort_by: sort_by }))
        end

        def get_chat(jid:)
          get("/api/chat", query: { jid: jid })
        end

        def direct_chat(phone:)
          get("/api/direct_chat", query: { phone: phone })
        end

        def contact_chats(jid:, limit: nil, page: nil)
          get("/api/contact_chats", query: compact_query({ jid: jid, limit: limit, page: page }))
        end

        def list_messages(after: nil, before: nil, sender: nil, chat_jid: nil, query: nil, limit: nil, page: nil)
          get(
            "/api/messages",
            query: compact_query({
              after: after,
              before: before,
              sender: sender,
              chat_jid: chat_jid,
              query: query,
              limit: limit,
              page: page
            }),
          )
        end

        def message_context(message_id:, before: nil, after: nil)
          get("/api/message_context", query: compact_query({ message_id: message_id, before: before, after: after }))
        end

        def last_interaction(jid:)
          get("/api/last_interaction", query: { jid: jid })
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
          if auth && @token.present?
            http_request["X-Bridge-Token"] = @token
          end

          response = Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: [ @timeout, 5 ].min,
            read_timeout: @timeout,
            write_timeout: @timeout,
          ) { |http| http.request(http_request) }

          parsed = parse_body(response.body)
          unless response.is_a?(Net::HTTPSuccess)
            detail = parsed.is_a?(Hash) ? (parsed["error"] || parsed["message"] || parsed) : parsed
            raise Error, "WhatsApp bridge #{response.code}: #{detail}"
          end
          parsed
        rescue Timeout::Error, SocketError, SystemCallError, EOFError => e
          raise Error, "WhatsApp bridge network error: #{e.message}"
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

        def pairing_code?(body)
          body.is_a?(Hash) && body["qr_png_base64"].present?
        end

        def pairing_failed?(detail)
          detail.match?(/outdated|pairing failed|rejected this companion/i)
        end

        def truthy?(value)
          value == true || value.to_s == "true"
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
