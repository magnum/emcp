# frozen_string_literal: true

class TelegramFlushJob < ApplicationJob
  queue_as :default

  def perform(hook_id, chat_id, token)
    hook = Emcp::Servers::Telegram::Hook.find_by(id: hook_id)
    hook&.flush!(chat_id, token)
  end
end
