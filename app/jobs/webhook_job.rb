# frozen_string_literal: true

class WebhookJob < ApplicationJob
  queue_as :webhooks

  # A read timeout means the body may already have been accepted. Retrying it
  # runs the receiver a second time, so that attempt is final.
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(id)
    webhook = nil
    webhook = Webhook.find(id)
    return if finished?(webhook)
    return unless claim!(webhook)

    webhook.doCall!
    webhook.complete!
  rescue Net::ReadTimeout, Timeout::Error => e
    mark_delivered(webhook, e)
  rescue ActiveRecord::RecordNotFound
    nil
  rescue StandardError => e
    webhook.error!(e) if webhook
    release_claim(webhook) if webhook && retryable_failure?(webhook)
    raise e unless webhook&.response_code.to_i.between?(400, 499)
  end

  private

  def finished?(webhook)
    webhook.completed? || webhook.response_code == 200 || client_error?(webhook) || delivered_attempt?(webhook)
  end

  def client_error?(webhook)
    webhook.error? && webhook.response_code.to_i.between?(400, 499)
  end

  def delivered_attempt?(webhook)
    webhook.error_message.to_s.start_with?("delivered:")
  end

  def claim!(webhook)
    return true if webhook.response_code.to_i.between?(500, 599)

    Rails.cache.write(claim_key(webhook), true, unless_exist: true, expires_in: 1.day)
  end

  def release_claim(webhook)
    Rails.cache.delete(claim_key(webhook))
  end

  def claim_key(webhook) = "webhook/delivery/#{webhook.id}"

  def mark_delivered(webhook, error)
    return unless webhook

    webhook.error!(error)
    webhook.update_columns(error_message: "delivered:#{error.message}")
  end

  def retryable_failure?(webhook)
    code = webhook.response_code.to_i
    code.between?(500, 599) || webhook.response_code.nil?
  end
end
