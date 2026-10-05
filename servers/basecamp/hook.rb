# frozen_string_literal: true

require "uri"

module Emcp
  module Servers
    module Basecamp
      class Hook < ApplicationRecord
        self.table_name = "basecamp_hooks"

        include Webhookable

        belongs_to :mcp_server
        has_many :receipts, class_name: "Emcp::Servers::Basecamp::Hook::Receipt",
                 foreign_key: :basecamp_hook_id, dependent: :destroy, inverse_of: :hook

        encrypts :secret
        self.filter_attributes += [ :secret ]

        normalizes :url, with: ->(value) { value.to_s.strip }
        normalizes :secret_header, with: ->(value) { value.to_s.strip }

        validates :url, :secret, :secret_header, presence: true
        validates :secret, length: { minimum: 8 }, format: { without: /[\r\n]/ }
        validates :secret_header, format: { with: /\A[A-Za-z0-9-]+\z/ }
        validate :https_url

        scope :enabled, -> { where(enabled: true) }

        def self.model_name
          ActiveModel::Name.new(self, nil, "BasecampHook")
        end

        def deliver_event!(project, event)
          event_id = event["id"].to_s
          return if event_id.blank?
          return unless enabled?

          transaction do
            receipt = receipts.create!(event_id: event_id, outcome: "sent")
            webhook = webhook!(
              :post,
              url,
              body: JSON.generate(payload(project, event)),
              headers: request_headers,
              async: true,
              tags: [ "basecamp", event["kind"].to_s.presence || "event" ],
            )
            receipt.update!(webhook: webhook)
          end
        rescue ActiveRecord::RecordNotUnique
          nil
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
            tags: [ "basecamp", "test" ],
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
          self.table_name = "basecamp_hook_receipts"

          belongs_to :hook, class_name: "Emcp::Servers::Basecamp::Hook", foreign_key: :basecamp_hook_id, inverse_of: :receipts
          belongs_to :webhook, optional: true

          enum :outcome, { sent: "sent", filtered: "filtered" }, validate: true

          def message_id = event_id
        end

        private

        def payload(project, event)
          {
            event: "basecamp.event",
            instance: mcp_server.activity_log_code,
            project_id: project.project_id,
            project_name: project.name,
            kind: event["kind"],
            basecamp: event,
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
