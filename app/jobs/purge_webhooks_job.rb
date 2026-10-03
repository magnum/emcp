# frozen_string_literal: true

# Deletes outbound Webhook rows older than ENV["WEBHOOK_RETAIN"] (default 7 days).
class PurgeWebhooksJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: -> { "purge_webhooks" }, duration: 10.minutes

  def perform
    Webhook.purge_expired
  end
end
