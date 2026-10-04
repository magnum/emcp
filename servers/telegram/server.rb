# frozen_string_literal: true

require "securerandom"
require_relative "telegram_client"
require_relative "keepalive"
require_relative "hook"
require_relative "inbound_message"
require_relative "dispatch"

module Emcp
  module Servers
    module Telegram
      class Server < ::McpServer
        server_id "telegram"
        display_name "Telegram"
        description "Read chats and messages and send Telegram messages via a linked personal account (MTProto)."
        version "0.1.0"

        CHAT_SORTS = %w[last_active name].freeze
        CHAT_TYPES = %w[private group channel].freeze

        def instructions
          "Use Telegram tools to search contacts, list chats, read messages, and send text. " \
            "recipient is a @username, a phone number with country code and no +, or a numeric chat_id. " \
            "Reads never send read receipts. " \
            "Write tools stay disabled unless allow_write is on for this instance. " \
            "This links a personal Telegram account over MTProto, not the Bot API. " \
            "Incoming messages can call the webhooks configured on this instance."
        end

        def auth_help_content
          {
            title: "Link a Telegram account",
            description: "EmCP runs a local MTProto bridge (gotd). " \
                         "Create api_id and api_hash at my.telegram.org, then sign in with your phone number.",
            steps: [
              "At my.telegram.org open API development tools and copy api_id and api_hash for this instance.",
              "Enter them with the phone number (country code, no +). Leave the bridge URL blank to use the bundled bridge.",
              "Click Start linking. Telegram sends a login code to that phone.",
              "Enter the code and click Submit code. If the account has a cloud password, enter it and click Submit password.",
              "The session is stored encrypted under this instance’s data directory and is reused after a restart.",
            ],
            note: "The bridge makes outbound MTProto calls to Telegram from this host. No extra inbound ports. " \
                  "Login code and 2FA password are sent to the bridge and are not saved. " \
                  "Reading messages does not mark them as read.",
          }
        end

        def auth_fields
          [
            {
              name: "telegram_api_id",
              label: "API ID",
              type: "text",
              required: true,
              help: "Numeric api_id from my.telegram.org.",
              env: "TELEGRAM_API_ID",
            },
            {
              name: "telegram_api_hash",
              label: "API hash",
              type: "password",
              required: true,
              help: "api_hash from my.telegram.org. Leave blank to keep the saved hash.",
              env: "TELEGRAM_API_HASH",
            },
            {
              name: "telegram_phone",
              label: "Phone number",
              type: "text",
              required: true,
              help: "Country code, digits only. Example: 393331234567.",
              env: "TELEGRAM_PHONE",
            },
            {
              name: "telegram_code",
              label: "Login code",
              type: "text",
              required: false,
              help: "The code Telegram sent after Start linking. Not stored.",
            },
            {
              name: "telegram_password",
              label: "2FA password",
              type: "password",
              required: false,
              help: "Cloud password, only if Telegram asks for it. Not stored.",
            },
            {
              name: "telegram_bridge_url",
              label: "Bridge URL (optional)",
              type: "text",
              required: false,
              help: "Leave blank to spawn the bundled bridge. Example: http://127.0.0.1:8080",
              env: "TELEGRAM_BRIDGE_URL",
            },
            {
              name: "telegram_bridge_token",
              label: "Bridge token (optional)",
              type: "password",
              required: false,
              help: "Shared secret sent as X-Bridge-Token. Generated automatically for the bundled bridge.",
              env: "TELEGRAM_BRIDGE_TOKEN",
            },
          ]
        end

        def auth_submit_label
          status = auth_status
          return "Save credentials" if status[:authenticated]
          return "Submit password" if status[:auth_step].to_s == "password"
          return "Submit code" if status[:auth_step].to_s == "code"

          "Start linking"
        end

        def auth_status_cache_ttl = 0

        def fetch_auth_status
          load_credentials!
          unless @client.credentials_ready?
            return { authenticated: false, pairing: false, auth_step: "credentials", error: nil }
          end
          unless @client.bridge_configured?
            return { authenticated: false, pairing: false, auth_step: "bridge", error: @client.unreachable_reason }
          end

          @client.ensure_bridge! if @client.managed?
          unless @client.reachable?
            return { authenticated: false, pairing: false, auth_step: "bridge", error: @client.unreachable_reason }
          end

          link_status(@client.status)
        rescue StandardError => e
          { authenticated: false, pairing: false, auth_step: "error", error: e.message }
        end

        def keep_bridge_alive!
          load_credentials!
          return false unless @client.managed?
          return false unless @client.credentials_ready? && @client.session_stored?

          @client.ensure_bridge!
          true
        end

        def apply_credentials(params)
          api_id = Emcp.sanitize_env_value(params["telegram_api_id"])
          api_hash = Emcp.sanitize_env_value(params["telegram_api_hash"])
          phone = Emcp.sanitize_env_value(params["telegram_phone"]).gsub(/\D/, "")
          url = Emcp.sanitize_env_value(params["telegram_bridge_url"])
          token = Emcp.sanitize_env_value(params["telegram_bridge_token"])
          code = params["telegram_code"].to_s.strip
          password = params["telegram_password"].to_s
          api_hash = Emcp.sanitize_env_value(ENV["TELEGRAM_API_HASH"]) if api_hash.blank?
          token = existing_or_generated_token if token.blank? && url.blank?
          session_key = Emcp.sanitize_env_value(ENV["TELEGRAM_SESSION_KEY"]).presence || SecureRandom.hex(32)

          raise "TELEGRAM_API_ID is required" if api_id.blank?
          raise "TELEGRAM_API_HASH is required" if api_hash.blank?
          raise "TELEGRAM_PHONE is required" if phone.blank?
          raise "api_id must be numeric" unless api_id.match?(/\A\d+\z/)

          persist_credentials!(
            "TELEGRAM_API_ID" => api_id,
            "TELEGRAM_API_HASH" => api_hash,
            "TELEGRAM_PHONE" => phone,
            "TELEGRAM_BRIDGE_URL" => url,
            "TELEGRAM_BRIDGE_TOKEN" => token,
            "TELEGRAM_SESSION_KEY" => session_key,
          )
          replace_client!
          if code.present? || password.present?
            @client.ensure_bridge!
            @client.submit_code!(code) if code.present?
            @client.submit_password!(password) if password.present?
          elsif url.blank?
            @client.restart_bridge!
          else
            @client.ensure_bridge!
          end
          true
        end

        def clear_credentials!
          load_credentials!
          @client.logout if @client.reachable?
        rescue Client::Error
          nil
        ensure
          session = @client&.session_file
          @client&.stop_bridge!
          FileUtils.rm_f(session) if session
          persist_credentials!(
            "TELEGRAM_API_ID" => nil,
            "TELEGRAM_API_HASH" => nil,
            "TELEGRAM_PHONE" => nil,
            "TELEGRAM_BRIDGE_URL" => nil,
            "TELEGRAM_BRIDGE_TOKEN" => nil,
            "TELEGRAM_SESSION_KEY" => nil,
          )
          replace_client!
        end

        def configure_tools
          define_read_tools
          define_write_tools
        end

        def api_response(result = nil)
          @client.ensure_bridge!
          super
        end

        def replace_client!
          load_credentials! if persisted?
          @client = Client.new(
            base_url: ENV["TELEGRAM_BRIDGE_URL"],
            token: ENV["TELEGRAM_BRIDGE_TOKEN"],
            store_dir: File.join(data_dir, "telegram"),
            binary: ENV["TELEGRAM_BRIDGE_BIN"],
            timeout: ENV.fetch("TELEGRAM_TIMEOUT", "30").to_i,
            inbound_url: inbound_messages_url,
            api_id: ENV["TELEGRAM_API_ID"],
            api_hash: ENV["TELEGRAM_API_HASH"],
            phone: ENV["TELEGRAM_PHONE"],
            session_key: ENV["TELEGRAM_SESSION_KEY"],
          )
        end

        def inbound_messages_url
          return if id.blank?

          "#{Emcp.public_url}/servers/#{id}/inbound_messages"
        end

        has_many :telegram_hooks, class_name: "Emcp::Servers::Telegram::Hook",
                 foreign_key: :mcp_server_id, dependent: :destroy

        def accept_inbound_message!(attrs)
          message = InboundMessage.new(attrs)
          return if message.skip_webhook?

          telegram_hooks.enabled.find_each { |hook| hook.deliver_message!(message) }
        end

        def set_owner_status!(status, webhook_id: nil)
          value = status.to_s
          raise ArgumentError, "status must be active or away" unless %w[active away].include?(value)

          scope = telegram_hooks
          scope = scope.where(id: webhook_id) if webhook_id.present?
          raise "No Telegram webhooks configured" unless scope.exists?

          scope.update_all(owner_status: value, updated_at: Time.current)
          telegram_hooks.order(:id).map { |hook| { "id" => hook.id, "owner_status" => hook.owner_status } }
        end

        def credential_env_keys
          %w[
            TELEGRAM_API_ID
            TELEGRAM_API_HASH
            TELEGRAM_PHONE
            TELEGRAM_BRIDGE_URL
            TELEGRAM_BRIDGE_TOKEN
            TELEGRAM_SESSION_KEY
          ]
        end

        private

        def link_status(raw)
          body = stringify_keys(raw.is_a?(Hash) ? raw : {})
          logged_in = truthy?(body["logged_in"])
          connected = truthy?(body["connected"])
          step = body["auth_step"].to_s
          step = "ready" if logged_in && connected && step.blank?
          {
            authenticated: logged_in && connected,
            connected: connected,
            logged_in: logged_in,
            pairing: %w[code password].include?(step),
            auth_step: step,
            user_id: body["user_id"],
            username: body["username"],
            name: body["name"],
            phone: body["phone"],
            error: body["error"],
          }
        end

        def truthy?(value)
          value == true || value.to_s == "true"
        end

        def existing_or_generated_token
          stored = Emcp.sanitize_env_value(ENV["TELEGRAM_BRIDGE_TOKEN"])
          stored.presence || SecureRandom.hex(24)
        end

        def define_read_tools
          define_tool(
            name: "telegram_status",
            description: "Show whether this instance is linked and the Telegram user id.",
          ) do
            api_response do
              body = stringify_keys(@client.status)
              {
                "connected" => truthy?(body["logged_in"]) && truthy?(body["connected"]),
                "user_id" => body["user_id"],
                "username" => body["username"],
                "name" => body["name"],
                "phone" => body["phone"],
              }
            end
          end

          define_tool(
            name: "telegram_search_contacts",
            description: "Search Telegram contacts by name, username, or phone.",
            properties: { query: string_prop("Name, @username, or phone fragment") },
            required: [ "query" ],
          ) { |query:| api_response { @client.search_contacts(query: query) } }

          define_tool(
            name: "telegram_list_chats",
            description: "List chats with id, title, type, unread_count, muted, and the last message. Does not mark chats read.",
            properties: {
              query: string_prop("Optional title filter"),
              limit: integer_prop("Maximum chats to return (default 20)"),
              page: integer_prop("Page number, 0-based"),
              sort_by: string_prop("last_active (default) or name"),
              type: string_prop("Optional private, group, or channel"),
            },
          ) do |query: nil, limit: nil, page: nil, sort_by: nil, type: nil|
            api_response do
              sort = sort_by.to_s.strip
              sort = "last_active" if sort.empty?
              raise "sort_by must be last_active or name" unless CHAT_SORTS.include?(sort)

              kind = type.to_s.strip
              raise "type must be private, group, or channel" if kind.present? && !CHAT_TYPES.include?(kind)

              @client.list_chats(query: query, limit: limit, page: page, sort_by: sort, type: kind.presence)
            end
          end

          define_tool(
            name: "telegram_get_chat",
            description: "Get one Telegram chat by id. Does not mark it read.",
            properties: { chat_id: string_prop("Numeric chat id") },
            required: [ "chat_id" ],
          ) { |chat_id:| api_response { @client.get_chat(chat_id: chat_id) } }

          define_tool(
            name: "telegram_list_messages",
            description: "List messages. Timestamps are RFC3339 UTC. Does not send read receipts.",
            properties: {
              chat_id: string_prop("Optional numeric chat id"),
              sender: string_prop("Optional sender id or @username"),
              query: string_prop("Optional text search"),
              after: string_prop("Only messages after this RFC3339 timestamp"),
              before: string_prop("Only messages before this RFC3339 timestamp"),
              limit: integer_prop("Maximum messages (default 20)"),
              page: integer_prop("Page number, 0-based"),
            },
          ) do |chat_id: nil, sender: nil, query: nil, after: nil, before: nil, limit: nil, page: nil|
            api_response do
              @client.list_messages(
                chat_id: chat_id, sender: sender, query: query, after: after, before: before, limit: limit, page: page,
              )
            end
          end

          define_tool(
            name: "telegram_get_message_context",
            description: "Return a message plus neighboring messages in the same chat. Does not mark them read.",
            properties: {
              chat_id: string_prop("Numeric chat id"),
              message_id: string_prop("Message id"),
              before: integer_prop("Messages before the target (default 5)"),
              after: integer_prop("Messages after the target (default 5)"),
            },
            required: %w[chat_id message_id],
          ) do |chat_id:, message_id:, before: nil, after: nil|
            api_response { @client.message_context(chat_id: chat_id, message_id: message_id, before: before, after: after) }
          end

          define_tool(
            name: "telegram_get_last_interaction",
            description: "Return the most recent message with a peer. Does not mark it read.",
            properties: { peer_id: string_prop("User id, chat id, or @username") },
            required: [ "peer_id" ],
          ) { |peer_id:| api_response { @client.last_interaction(peer_id: peer_id) } }

          define_tool(
            name: "telegram_list_unread",
            description: "List chats that have unread messages, for a periodic check. Does not mark them read.",
            properties: { limit: integer_prop("Maximum chats (default 20)") },
          ) { |limit: nil| api_response { @client.list_unread(limit: limit) } }
        end

        def define_write_tools
          define_tool(
            name: "telegram_send_message",
            description: "Send a Telegram text message. recipient is a @username, phone number, or numeric chat_id.",
            properties: {
              recipient: string_prop("@username, phone with country code and no +, or numeric chat_id"),
              message: string_prop("Plain text to send"),
              reply_to_message_id: string_prop("Optional message id to reply to"),
            },
            required: %w[recipient message],
            write: true,
          ) do |recipient:, message:, reply_to_message_id: nil|
            api_response do
              @client.send_message(recipient: recipient, message: message, reply_to_message_id: reply_to_message_id)
            end
          end

          define_tool(
            name: "telegram_set_owner_status",
            description: "Set owner presence (active or away) for this instance’s Telegram webhooks. " \
                         "Omit webhook_id to update every webhook. Does not send a Telegram message.",
            properties: {
              status: string_prop("active or away"),
              webhook_id: string_prop("Optional webhook id. Omit to update every webhook on this instance."),
            },
            required: [ "status" ],
            write: true,
          ) { |status:, webhook_id: nil| config_response { set_owner_status!(status, webhook_id: webhook_id) } }
        end

        def config_response
          ::McpServer.instance_method(:api_response).bind_call(self) { yield }
        end
      end
    end
  end
end

Emcp.register_integration(Emcp::Servers::Telegram::Server)
