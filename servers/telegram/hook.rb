# frozen_string_literal: true

require "uri"
require_relative "dispatch"
require_relative "aggregator"

module Emcp
  module Servers
    module Telegram
      class Hook < ApplicationRecord
        self.table_name = "telegram_hooks"

        include Webhookable

        belongs_to :mcp_server
        has_many :receipts, class_name: "Emcp::Servers::Telegram::Hook::Receipt",
                 foreign_key: :telegram_hook_id, dependent: :destroy, inverse_of: :hook

        encrypts :secret
        self.filter_attributes += [ :secret ]

        CHAT_TYPES = {
          "private" => "Private chats",
          "group" => "Groups",
          "channel" => "Channels",
        }.freeze

        enum :owner_status, { active: "active", away: "away" }, prefix: :owner, validate: true
        enum :respond_by_status, { every: "every", active: "active", away: "away" }, prefix: :respond, validate: true

        normalizes :url, with: ->(value) { value.to_s.strip }
        normalizes :secret_header, with: ->(value) { value.to_s.strip }
        normalizes :chat_ids, with: ->(value) { value.to_s.split(/[\s,]+/).map(&:strip).reject(&:blank?).uniq.join(",") }

        validates :url, :secret, :secret_header, presence: true
        validates :secret, length: { minimum: 8 }, format: { without: /[\r\n]/ }
        validates :secret_header, format: { with: /\A[A-Za-z0-9-]+\z/ }
        validates :debounce_minutes, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 1440 }
        validate :https_url

        scope :enabled, -> { where(enabled: true) }

        def self.model_name
          ActiveModel::Name.new(self, nil, "TelegramHook")
        end

        def self.normalize_chat_types(value)
          picked = Array(value).flat_map { |part| part.to_s.split(",") }.map(&:strip).reject(&:blank?)
          CHAT_TYPES.keys.select { |kind| picked.include?(kind) }.join(",")
        end

        def chat_types=(value)
          super(self.class.normalize_chat_types(value))
        end

        def selected_chat_types
          chat_types.to_s.split(",").map(&:strip).reject(&:blank?)
        end

        def accepts_chat_type?(type)
          selected_chat_types.include?(type.to_s)
        end

        def accepts_chat_id?(chat_id)
          allowed = chat_ids.to_s.split(",").map(&:strip).reject(&:blank?)
          return true if allowed.empty?

          allowed.include?(chat_id.to_s)
        end

        def deliver_message!(message)
          Dispatch.new(self, message).deliver!
        end

        def post_batch!(chat_id, messages)
          rows = Array(messages)
          return if rows.empty?

          first = rows.first
          webhook = webhook!(
            :post,
            url,
            body: JSON.generate(payload(chat_id, first, rows)),
            headers: request_headers,
            async: true,
            tags: [ "telegram", "messages.received" ],
          )
          ids = rows.filter_map { |row| row["message_id"].presence }
          receipts.where(message_id: ids, webhook_id: nil).update_all(webhook_id: webhook.id)
          webhook
        end

        def flush!(chat_id, token)
          key = Aggregator.cache_key(self, chat_id)
          batch = Rails.cache.read(key)
          stored = batch.is_a?(Hash) ? batch["token"].to_s : ""
          presented = token.to_s
          return if stored.blank? || presented.blank?
          return unless stored.bytesize == presented.bytesize && ActiveSupport::SecurityUtils.secure_compare(stored, presented)

          Rails.cache.delete(key)
          post_batch!(chat_id, batch["messages"])
        end

        def deliver_test!
          webhook!(
            :post,
            url,
            body: {
              event: "webhook.test",
              instance: mcp_server.activity_log_code,
              webhook_id: id,
              timestamp: Time.now.utc.iso8601,
            }.to_json,
            headers: request_headers,
            async: false,
            tags: [ "telegram", "test" ],
          ).reload
        end

        def request_headers
          {
            "Content-Type" => "application/json",
            secret_header => "Bearer #{secret}",
          }
        end

        def as_json(options = nil)
          options ||= {}
          super(options.merge(except: Array(options[:except]) + [ :secret ]))
        end

        class Receipt < ApplicationRecord
          self.table_name = "telegram_hook_receipts"

          belongs_to :hook, class_name: "Emcp::Servers::Telegram::Hook", foreign_key: :telegram_hook_id, inverse_of: :receipts
          belongs_to :webhook, optional: true

          enum :outcome, { sent: "sent", filtered: "filtered" }, validate: true
        end

        private

        def payload(chat_id, first, rows)
          {
            "event" => "messages.received",
            "instance" => mcp_server.activity_log_code,
            "webhook_id" => id,
            "chat_id" => chat_id.to_s,
            "chat_title" => first["chat_title"],
            "chat_type" => first["chat_type"],
            "owner_status" => owner_status,
            "messages" => rows,
          }
        end

        def https_url
          uri = URI.parse(url.to_s)
          schemes = Rails.env.production? ? %w[https] : %w[http https]
          return if schemes.include?(uri.scheme) && uri.host.present?

          errors.add(:url, "must be an https URL")
        rescue URI::InvalidURIError
          errors.add(:url, "must be an https URL")
        end
      end
    end
  end
end
