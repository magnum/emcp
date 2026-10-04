# frozen_string_literal: true

module Emcp
  module Servers
    module Telegram
      class InboundMessage
        def initialize(attrs)
          @attributes = attrs.to_h.stringify_keys
        end

        attr_reader :attributes

        def id = attributes["message_id"].to_s

        def chat_id = attributes["chat_id"].to_s

        def text = attributes["text"].to_s

        def chat_type
          type = attributes["chat_type"].to_s
          return type if %w[private group channel].include?(type)

          "private"
        end

        def from_me? = ActiveModel::Type::Boolean.new.cast(attributes["is_from_me"])

        def skip_webhook? = ActiveModel::Type::Boolean.new.cast(attributes["skip_webhook"]) || from_me?

        def mentions_owner? = ActiveModel::Type::Boolean.new.cast(attributes["mentions_owner"])

        def muted? = ActiveModel::Type::Boolean.new.cast(attributes["muted"])

        def channel? = chat_type == "channel"

        def private? = chat_type == "private"

        def timestamp
          Time.iso8601(attributes["timestamp"].to_s).utc.iso8601
        rescue ArgumentError
          Time.now.utc.iso8601
        end

        def to_h
          {
            "message_id" => id,
            "timestamp" => timestamp,
            "chat_id" => chat_id,
            "chat_title" => attributes["chat_title"].to_s,
            "chat_type" => chat_type,
            "sender_id" => attributes["sender_id"].to_s,
            "sender_name" => attributes["sender_name"].to_s,
            "text" => text,
            "mentions_owner" => mentions_owner?,
            "muted" => muted?,
          }
        end
      end
    end
  end
end
