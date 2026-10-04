# frozen_string_literal: true

require_relative "aggregator"

module Emcp
  module Servers
    module Telegram
      class Dispatch
        Decision = Struct.new(:deliver, :skip_reason, :match_reason, keyword_init: true) do
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
          Aggregator.enqueue(hook, message) if decision.deliver?
          receipt
        rescue ActiveRecord::RecordNotUnique
          nil
        end

        def decision_for
          return skip("from_me") if message.from_me? || message.skip_webhook?
          return skip("channel") if hook.ignore_channels? && message.channel?
          return skip(message.chat_type) unless hook.accepts_chat_type?(message.chat_type)
          return skip("chat_id") unless hook.accepts_chat_id?(message.chat_id)
          return skip("muted") if hook.ignore_muted? && message.muted?
          return skip("mention") if hook.mentions_only? && !message.private? && !message.mentions_owner?

          case hook.respond_by_status
          when "active"
            return skip("owner_status") unless hook.owner_active?
          when "away"
            return skip("owner_status") unless hook.owner_away?
          end

          Decision.new(deliver: true, match_reason: "message")
        end

        private

        attr_reader :hook, :message

        def skip(reason)
          Decision.new(deliver: false, skip_reason: reason)
        end
      end
    end
  end
end
