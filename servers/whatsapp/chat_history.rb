# frozen_string_literal: true

module Emcp
  module Servers
    module Whatsapp
      # Rolling per-chat window in Solid Cache. Every inbound message is stored,
      # including ones that do not fire a webhook.
      class ChatHistory
        ENV_KEY = "WHATSAPP_WEBHOOK_CHAT_HISTORY"
        DEFAULT_LIMIT = 100
        MAX_STORED = 1000

        LOCKS = Concurrent::Map.new

        def self.limit
          value = ENV.fetch(ENV_KEY, DEFAULT_LIMIT.to_s).to_i
          value.positive? ? value : DEFAULT_LIMIT
        end

        def self.record!(server_id, message)
          return if server_id.blank? || message.id.blank? || message.chat_jid.blank?

          cache_key = key(server_id, message.chat_jid)
          lock_for(cache_key).synchronize do
            entries = Array(Rails.cache.read(cache_key)).reject { |entry| entry["message_id"] == message.id }
            entries << snapshot(message)
            entries.sort_by! { |entry| [ entry["timestamp"].to_s, entry["message_id"].to_s ] }
            Rails.cache.write(cache_key, entries.last(MAX_STORED))
          end
        end

        def self.for(server_id, chat_jid, limit: self.limit)
          return [] if server_id.blank? || chat_jid.blank?

          size = limit.to_i
          return [] if size <= 0

          Array(Rails.cache.read(key(server_id, chat_jid))).last(size.clamp(1, MAX_STORED))
        end

        def self.key(server_id, chat_jid)
          "whatsapp/chat_history/#{server_id}/#{chat_jid}"
        end

        def self.snapshot(message)
          {
            "message_id" => message.id,
            "timestamp" => message.timestamp,
            "chat_jid" => message.chat_jid,
            "chat_name" => message.attributes["chat_name"].presence,
            "is_group" => message.group?,
            "sender_jid" => message.attributes["sender_jid"].presence,
            "sender_phone" => message.phone.presence,
            "sender_name" => message.attributes["sender_name"].presence,
            "is_from_me" => message.from_me?,
            "type" => message.attributes["type"].presence || "text",
            "text" => message.text,
            "quoted_message_id" => message.attributes["quoted_message_id"].presence,
            "mentions_owner" => message.mentions_owner?,
            "media" => message.media,
          }
        end

        def self.lock_for(cache_key)
          LOCKS.compute_if_absent(cache_key) { Mutex.new }
        end
        private_class_method :snapshot, :lock_for
      end
    end
  end
end
