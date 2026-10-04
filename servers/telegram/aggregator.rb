# frozen_string_literal: true

require "securerandom"

module Emcp
  module Servers
    module Telegram
      # One webhook event per chat per debounce window. Later messages in the
      # same window are appended; the timer is not reset.
      class Aggregator
        def self.enqueue(hook, message)
          minutes = hook.debounce_minutes.to_i
          if minutes <= 0
            hook.post_batch!(message.chat_id, [ message.to_h ])
            return
          end

          key = cache_key(hook, message.chat_id)
          batch = Rails.cache.read(key)
          if batch.is_a?(Hash) && batch["token"].present?
            batch["messages"] = Array(batch["messages"]) + [ message.to_h ]
            Rails.cache.write(key, batch, expires_in: (minutes + 10).minutes)
            return
          end

          token = SecureRandom.hex(8)
          Rails.cache.write(
            key,
            { "token" => token, "messages" => [ message.to_h ] },
            expires_in: (minutes + 10).minutes,
          )
          TelegramFlushJob.set(wait: minutes.minutes).perform_later(hook.id, message.chat_id, token)
        end

        def self.cache_key(hook, chat_id)
          "telegram/hook/#{hook.id}/chat/#{chat_id}"
        end
      end
    end
  end
end
