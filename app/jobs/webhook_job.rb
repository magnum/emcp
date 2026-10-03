# frozen_string_literal: true

class WebhookJob < ApplicationJob
  queue_as :webhooks

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(id)
    webhook = nil
    webhook = Webhook.find(id)
    webhook.doCall!
    webhook.complete!
  rescue ActiveRecord::RecordNotFound
    nil
  rescue StandardError => e
    webhook.error!(e) if webhook
    raise e unless webhook&.response_code.to_i.between?(400, 499)
  end
end
