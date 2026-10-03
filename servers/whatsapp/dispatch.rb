# frozen_string_literal: true

require_relative "chat_history"

module Emcp
  module Servers
    module Whatsapp
      # Decides if one configured hook should fire. The app-wide Webhook is
      # created only when the message passes.
      class Dispatch
        Decision = Struct.new(:deliver, :skip_reason, :match_reason, :matched_words, keyword_init: true) do
          def deliver? = deliver
        end

        def initialize(hook, message)
          @hook = hook
          @message = message
        end

        def deliver!
          ChatHistory.record!(hook.mcp_server_id, message)
          return if message.id.blank?
          return if hook.receipts.exists?(message_id: message.id)

          decision = decision_for
          decision = skip("duplicate") if decision.deliver? && !claim_url!
          receipt = hook.receipts.create!(
            message_id: message.id,
            outcome: decision.deliver? ? "sent" : "filtered",
            reason: decision.deliver? ? decision.match_reason : decision.skip_reason,
          )
          log_receipt(receipt)
          return receipt unless decision.deliver?

          webhook = hook.webhook!(
            :post,
            hook.url,
            body: JSON.generate(payload(decision)),
            headers: hook.request_headers,
            async: true,
            tags: [ "whatsapp", "message.received", decision.match_reason ],
          )
          receipt.update!(webhook: webhook)
          receipt
        rescue ActiveRecord::RecordNotUnique
          nil
        end

        def decision_for
          return skip(message.chat_kind) unless hook.accepts_chat?(message)

          words = matched_words(message.text)
          case hook.respond_when
          when "never"
            skip("never")
          when "always"
            deliver_decision("always", words)
          when "word"
            words.empty? ? skip("words") : deliver_decision("word", words)
          else
            message.mentions_owner? ? deliver_decision("mention", words) : skip("mention")
          end
        end

        private

        attr_reader :hook, :message

        def claim_url!
          Rails.cache.write(
            "whatsapp/hook_delivery/#{hook.mcp_server_id}/#{hook.url}/#{message.id}",
            hook.id,
            unless_exist: true,
            expires_in: 7.days,
          )
        rescue StandardError
          true
        end

        def payload(decision)
          {
            "event" => "message.received",
            "instance" => hook.mcp_server.activity_log_code,
            "webhook_id" => hook.id,
            "message_id" => message.id,
            "timestamp" => message.timestamp,
            "chat_jid" => message.attributes["chat_jid"],
            "chat_name" => message.attributes["chat_name"],
            "is_group" => message.group?,
            "sender_jid" => message.attributes["sender_jid"],
            "sender_phone" => message.phone,
            "sender_name" => message.attributes["sender_name"],
            "is_from_me" => message.from_me?,
            "type" => message.attributes["type"].presence || "text",
            "text" => message.text,
            "quoted_message_id" => message.attributes["quoted_message_id"].presence,
            "mentions_owner" => message.mentions_owner?,
            "matched_words" => decision.matched_words,
            "match_reason" => decision.match_reason,
            "owner_status" => hook.owner_status,
            "media" => message.media,
            "history" => ChatHistory.for(hook.mcp_server_id, message.chat_jid, limit: hook.history_size),
          }
        end

        def matched_words(text)
          tokens = hook.consider_words.to_s.split(",").map(&:strip).reject(&:blank?)
          return [] if text.blank?

          tokens.select { |token| text.match?(/(?<![[:alnum:]_])#{Regexp.escape(token)}(?![[:alnum:]_])/i) }
        end

        def deliver_decision(reason, words)
          Decision.new(deliver: true, match_reason: reason, matched_words: words)
        end

        def skip(reason)
          Decision.new(deliver: false, skip_reason: reason, matched_words: [])
        end

        def log_receipt(receipt)
          Rails.logger.info(
            "[#{hook.mcp_server.activity_log_code}] whatsapp_hook id=#{hook.id} " \
              "message_id=#{receipt.message_id} outcome=#{receipt.outcome} reason=#{receipt.reason}",
          )
        end
      end
    end
  end
end
