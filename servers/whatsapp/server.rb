# frozen_string_literal: true

require "securerandom"
require_relative "whatsapp_client"

module Emcp
  module Servers
    module Whatsapp
      class Server < ::McpServer
        server_id "whatsapp"
        display_name "WhatsApp"
        description "Search chats and contacts, read message history, and send WhatsApp messages via a linked personal account."
        version "0.1.0"

        def instructions
          "Use WhatsApp tools to search contacts, list chats, read messages, and send text. " \
            "Recipients are a phone number with country code and no +, or a JID " \
            "(example: 393331234567 or 393331234567@s.whatsapp.net, groups end with @g.us). " \
            "Write tools stay disabled unless WHATSAPP_ALLOW_WRITE=true. " \
            "This links a personal WhatsApp account as a companion device (whatsmeow), not the Cloud API."
        end

        def auth_help_content
          {
            title: "Link a WhatsApp account",
            description: "EmCP runs a local WhatsApp Web bridge based on " \
                         "lharries/whatsapp-mcp (whatsmeow). Scan the QR code with your phone " \
                         "to link this instance as a companion device.",
            steps: [
              "Leave the bridge URL blank to use the bundled bridge on this host, or point it at a running bridge.",
              "Click Start pairing. A QR code appears below when the bridge is waiting to link.",
              "On your phone: WhatsApp → Settings → Linked devices → Link a device, then scan the QR code.",
              "History can take a few minutes to sync after the first login."
            ],
            note: "WhatsApp limits linked devices. Session files live under this instance’s data directory. " \
                  "This unofficial Web API can be logged out by WhatsApp; treat it as personal/self-hosted use."
          }
        end

        def auth_fields
          [
            {
              name: "whatsapp_bridge_url",
              label: "Bridge URL (optional)",
              type: "text",
              required: false,
              help: "Leave blank to spawn the bundled bridge. Example: http://127.0.0.1:8080",
              env: "WHATSAPP_BRIDGE_URL"
            },
            {
              name: "whatsapp_bridge_token",
              label: "Bridge token (optional)",
              type: "password",
              required: false,
              help: "Shared secret sent as X-Bridge-Token. Generated automatically for the bundled bridge.",
              env: "WHATSAPP_BRIDGE_TOKEN"
            }
          ]
        end

        def auth_submit_label
          auth_status[:authenticated] ? "Save credentials" : "Start pairing"
        end

        def auth_status_cache_ttl = 0

        def fetch_auth_status
          load_credentials!
          unless @client.reachable?
            return {
              authenticated: false,
              pairing: false,
              error: @client.unreachable_reason
            }
          end

          pairing_status(@client.status)
        rescue StandardError => e
          {
            authenticated: false,
            pairing: false,
            error: e.message
          }
        end

        def apply_credentials(params)
          url = Emcp.sanitize_env_value(params["whatsapp_bridge_url"])
          token = Emcp.sanitize_env_value(params["whatsapp_bridge_token"])
          token = existing_or_generated_token if token.blank? && url.blank?

          persist_credentials!(
            "WHATSAPP_BRIDGE_URL" => url,
            "WHATSAPP_BRIDGE_TOKEN" => token,
          )
          replace_client!
          if url.blank?
            @client.restart_bridge!
            @client.wait_for_pairing_code!
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
          @client&.stop_bridge!
          persist_credentials!(
            "WHATSAPP_BRIDGE_URL" => nil,
            "WHATSAPP_BRIDGE_TOKEN" => nil,
          )
          replace_client!
        end

        def configure_tools
          define_read_tools
          define_write_tools
        end

        def replace_client!
          load_credentials! if persisted?
          @client = Client.new(
            base_url: ENV["WHATSAPP_BRIDGE_URL"],
            token: ENV["WHATSAPP_BRIDGE_TOKEN"],
            store_dir: File.join(data_dir, "whatsapp"),
            binary: ENV["WHATSAPP_BRIDGE_BIN"],
            timeout: ENV.fetch("WHATSAPP_TIMEOUT", "30").to_i,
          )
        end

        def credential_env_keys = %w[WHATSAPP_BRIDGE_URL WHATSAPP_BRIDGE_TOKEN]

        private

        def pairing_status(raw)
          body = stringify_keys(raw)
          logged_in = truthy?(body["logged_in"])
          connected = truthy?(body["connected"])
          {
            authenticated: logged_in && connected,
            connected: connected,
            logged_in: logged_in,
            pairing: truthy?(body["pairing"]),
            jid: body["jid"],
            push_name: body["push_name"],
            qr_png_base64: body["qr_png_base64"],
            qr: body["qr"],
            error: body["error"]
          }
        end

        def truthy?(value)
          value == true || value.to_s == "true"
        end

        def existing_or_generated_token
          stored = Emcp.sanitize_env_value(ENV["WHATSAPP_BRIDGE_TOKEN"])
          stored.presence || SecureRandom.hex(24)
        end

        def define_read_tools
          define_tool(
            name: "whatsapp_status",
            description: "Show whether this instance is linked to WhatsApp and the linked JID.",
          ) { api_response { @client.status } }

          define_tool(
            name: "whatsapp_search_contacts",
            description: "Search WhatsApp contacts by name or phone number.",
            properties: { query: string_prop("Name or phone number fragment") },
            required: [ "query" ],
          ) { |query:| api_response { @client.search_contacts(query: query) } }

          define_tool(
            name: "whatsapp_list_chats",
            description: "List WhatsApp chats with optional name/JID filter.",
            properties: {
              query: string_prop("Optional name or JID filter"),
              limit: integer_prop("Maximum chats to return (default 20)"),
              page: integer_prop("Page number, 0-based"),
              sort_by: string_prop("last_active (default) or name")
            },
          ) { |query: nil, limit: nil, page: nil, sort_by: nil| api_response { @client.list_chats(query: query, limit: limit, page: page, sort_by: sort_by) } }

          define_tool(
            name: "whatsapp_get_chat",
            description: "Get one WhatsApp chat by JID.",
            properties: { chat_jid: string_prop("Chat JID, e.g. 39333…@s.whatsapp.net or …@g.us") },
            required: [ "chat_jid" ],
          ) { |chat_jid:| api_response { @client.get_chat(jid: chat_jid) } }

          define_tool(
            name: "whatsapp_get_direct_chat_by_contact",
            description: "Find the direct chat for a phone number.",
            properties: { phone: string_prop("Phone number with country code, no +") },
            required: [ "phone" ],
          ) { |phone:| api_response { @client.direct_chat(phone: phone) } }

          define_tool(
            name: "whatsapp_get_contact_chats",
            description: "List chats that involve a contact JID.",
            properties: {
              jid: string_prop("Contact JID"),
              limit: integer_prop("Maximum chats to return"),
              page: integer_prop("Page number, 0-based")
            },
            required: [ "jid" ],
          ) { |jid:, limit: nil, page: nil| api_response { @client.contact_chats(jid: jid, limit: limit, page: page) } }

          define_tool(
            name: "whatsapp_list_messages",
            description: "List WhatsApp messages with optional filters (chat, sender, text, time range).",
            properties: {
              chat_jid: string_prop("Optional chat JID"),
              sender_phone_number: string_prop("Optional sender phone / JID user part"),
              query: string_prop("Optional text search"),
              after: string_prop("Only messages after this RFC3339 timestamp"),
              before: string_prop("Only messages before this RFC3339 timestamp"),
              limit: integer_prop("Maximum messages (default 20)"),
              page: integer_prop("Page number, 0-based")
            },
          ) do |chat_jid: nil, sender_phone_number: nil, query: nil, after: nil, before: nil, limit: nil, page: nil|
            api_response do
              @client.list_messages(
                chat_jid: chat_jid,
                sender: sender_phone_number,
                query: query,
                after: after,
                before: before,
                limit: limit,
                page: page,
              )
            end
          end

          define_tool(
            name: "whatsapp_get_message_context",
            description: "Return a message plus neighboring messages in the same chat.",
            properties: {
              message_id: string_prop("Message ID from list_messages"),
              before: integer_prop("Messages before the target (default 5)"),
              after: integer_prop("Messages after the target (default 5)")
            },
            required: [ "message_id" ],
          ) { |message_id:, before: nil, after: nil| api_response { @client.message_context(message_id: message_id, before: before, after: after) } }

          define_tool(
            name: "whatsapp_get_last_interaction",
            description: "Return the most recent message involving a contact JID.",
            properties: { jid: string_prop("Contact or chat JID") },
            required: [ "jid" ],
          ) { |jid:| api_response { @client.last_interaction(jid: jid) } }
        end

        def define_write_tools
          define_tool(
            name: "whatsapp_send_message",
            description: "Send a WhatsApp text message to a phone number or chat JID (write).",
            properties: {
              recipient: string_prop("Phone number with country code and no +, or a JID"),
              message: string_prop("Plain text to send")
            },
            required: %w[recipient message],
            write: true,
          ) { |recipient:, message:| api_response { @client.send_message(recipient: recipient, message: message) } }
        end
      end
    end
  end
end

Emcp.register_integration(Emcp::Servers::Whatsapp::Server)
