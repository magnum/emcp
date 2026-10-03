# frozen_string_literal: true

module Emcp
  module Servers
    module Whatsapp
      # One configured destination on a WhatsApp instance. Whether a message
      # is sent is decided by Dispatch; this record only calls the app-wide
      # Webhookable API when Dispatch says to send.
      class Hook < ApplicationRecord
        self.table_name = "whatsapp_hooks"

        include Webhookable

        belongs_to :mcp_server
        has_many :receipts, class_name: "Emcp::Servers::Whatsapp::Hook::Receipt",
                 foreign_key: :whatsapp_hook_id, dependent: :destroy, inverse_of: :hook

        encrypts :secret
        self.filter_attributes += [ :secret ]

        CHAT_KINDS = {
          "direct" => "Direct chats",
          "group" => "Groups",
          "status" => "Status",
          "newsletter" => "Channels",
          "broadcast" => "Broadcast lists",
        }.freeze

        enum :owner_status, { active: "active", away: "away" }, prefix: :owner, validate: true
        enum :respond_by_status, { every: "every", active: "active", away: "away" }, prefix: :respond, validate: true
        enum :respond_when, { never: "never", always: "always", mention: "mention", word: "word" }, prefix: :trigger, validate: true

        normalizes :url, with: ->(value) { value.to_s.strip }
        normalizes :secret_header, with: ->(value) { value.to_s.strip }
        normalizes :consider_words, with: ->(value) { value.to_s.split(",").map(&:strip).reject(&:blank?).join(", ") }
        normalizes :respond_numbers_filtered_in, :respond_numbers_filtered_out, with: ->(value) { normalize_phone_list(value) }

        validates :url, :secret, :secret_header, presence: true
        validates :secret, length: { minimum: 8 }, format: { without: /[\r\n]/ }
        validates :secret_header, format: { with: /\A[A-Za-z0-9-]+\z/ }
        validates :history_limit, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 1000 }, allow_nil: true
        validate :https_url

        scope :enabled, -> { where(enabled: true) }

        def self.model_name
          ActiveModel::Name.new(self, nil, "WhatsappHook")
        end

        def self.normalize_phone_list(value)
          value.to_s.split(",").filter_map { |part| part.gsub(/\D/, "").presence }.join(", ")
        end

        def self.normalize_chat_kinds(value)
          picked = Array(value).flat_map { |part| part.to_s.split(",") }.map(&:strip).reject(&:blank?)
          CHAT_KINDS.keys.select { |kind| picked.include?(kind) }.join(",")
        end

        def chat_kinds=(value)
          super(self.class.normalize_chat_kinds(value))
        end

        def selected_chat_kinds
          chat_kinds.to_s.split(",").map(&:strip).reject(&:blank?)
        end

        def accepts_chat?(message)
          selected_chat_kinds.include?(message.chat_kind)
        end

        def history_size
          return ChatHistory.limit if history_limit.nil?

          history_limit.to_i.clamp(0, ChatHistory::MAX_STORED)
        end

        def deliver_message!(message)
          Dispatch.new(self, message).deliver!
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
            tags: [ "whatsapp", "test" ],
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
          self.table_name = "whatsapp_hook_receipts"

          belongs_to :hook, class_name: "Emcp::Servers::Whatsapp::Hook", foreign_key: :whatsapp_hook_id, inverse_of: :receipts
          belongs_to :webhook, optional: true

          enum :outcome, { sent: "sent", filtered: "filtered" }, validate: true
        end

        private

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
