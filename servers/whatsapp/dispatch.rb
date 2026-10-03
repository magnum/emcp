# frozen_string_literal: true

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
          return if message.id.blank?
          return if hook.receipts.exists?(message_id: message.id)

          decision = decision_for
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
          words = matched_words(message.text)
          if message.from_me?
            return skip("from_me") if words.empty?

            return gate(match_reason: "words", matched_words: words)
          end

          if hook.consider_all_messages?
            return gate(match_reason: "all", matched_words: words)
          end
          if hook.consider_mentions? && message.addressed_to_owner?
            return gate(match_reason: "mention", matched_words: words)
          end
          return gate(match_reason: "words", matched_words: words) if words.any?

          skip("not_considered")
        end

        private

        attr_reader :hook, :message

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
            "mentions_owner" => message.addressed_to_owner?,
            "matched_words" => decision.matched_words,
            "match_reason" => decision.match_reason,
            "owner_status" => hook.owner_status,
            "media" => message.media,
          }
        end

        def matched_words(text)
          tokens = hook.consider_words.to_s.split(",").map(&:strip).reject(&:blank?)
          return [] if text.blank?

          tokens.select { |token| text.match?(/(?<![[:alnum:]_])#{Regexp.escape(token)}(?![[:alnum:]_])/i) }
        end

        def gate(match_reason:, matched_words:)
          phone = message.phone
          blocked = phone_list(hook.respond_numbers_filtered_out)
          allowed = phone_list(hook.respond_numbers_filtered_in)
          return skip("filtered_out") if phone.present? && blocked.include?(phone)
          return skip("filtered_in") if allowed.any? && !allowed.include?(phone)
          return skip("owner_status") unless status_allows?

          Decision.new(deliver: true, match_reason: match_reason, matched_words: matched_words)
        end

        def status_allows?
          return true if hook.respond_every?
          return hook.owner_active? if hook.respond_active?

          hook.owner_away?
        end

        def phone_list(raw)
          Hook.normalize_phone_list(raw).split(", ").reject(&:blank?)
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
