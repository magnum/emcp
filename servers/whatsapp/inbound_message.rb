# frozen_string_literal: true

module Emcp
  module Servers
    module Whatsapp
      class InboundMessage
        def initialize(attrs)
          @attributes = attrs.to_h.stringify_keys
        end

        attr_reader :attributes

        def id = attributes["message_id"].to_s

        def chat_jid = attributes["chat_jid"].to_s

        def text = attributes["text"].to_s

        def phone = attributes["sender_phone"].to_s.gsub(/\D/, "")

        def from_me? = ActiveModel::Type::Boolean.new.cast(attributes["is_from_me"])

        def skip_webhook? = ActiveModel::Type::Boolean.new.cast(attributes["skip_webhook"])

        def group? = ActiveModel::Type::Boolean.new.cast(attributes["is_group"])

        def mentions_owner? = ActiveModel::Type::Boolean.new.cast(attributes["mentions_owner"])

        def addressed_to_owner? = !group? || mentions_owner?

        def chat_kind
          user, server = chat_jid.downcase.split("@", 2)
          return "status" if server == "broadcast" && user == "status"
          return "newsletter" if server == "newsletter"
          return "broadcast" if server == "broadcast"
          return "group" if group? || server == "g.us"

          "direct"
        end

        def timestamp
          Time.iso8601(attributes["timestamp"].to_s).utc.iso8601
        rescue ArgumentError
          Time.now.utc.iso8601
        end

        def media
          raw = attributes["media"]
          return nil unless raw.respond_to?(:to_h)

          data = raw.to_h.stringify_keys
          mimetype = data["mimetype"].presence
          filename = data["filename"].presence
          return nil if mimetype.blank? && filename.blank?

          { "mimetype" => mimetype, "filename" => filename }
        end
      end
    end
  end
end
