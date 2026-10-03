# frozen_string_literal: true

require "httparty"

class Webhook < ApplicationRecord
  include ValidationSkippable

  DEFAULT_RETAIN_SECONDS = 604_800

  belongs_to :webhookable, polymorphic: true

  acts_as_taggable_on :tags

  self.filter_attributes += [ :headers, :body, :response_body ]

  validates :url, presence: true
  validates :method, presence: true

  include AASM

  after_create_commit do
    call!
  end

  def call!
    async? ? callAsync! : callSync!
  end

  aasm column: :state do
    state :created, initial: true
    state :pending
    state :completed
    state :error

    event :callSync do
      transitions from: [ :created, :error, :completed ], to: :completed, guard: -> { doCall! }
      error do |exception|
        error!(exception)
      end
    end

    event :callAsync do
      transitions from: [ :created, :error, :completed ], to: :pending
      before do
        WebhookJob.perform_later(id)
      end
    end

    event :complete do
      transitions to: :completed
      after do
        update_columns(error_message: nil, error_backtrace: nil)
      end
    end

    event :error, after: proc { |exception|
      if exception.present?
        update_columns(
          error_message: exception.message.to_s.truncate(500),
          error_backtrace: exception.backtrace&.join("\n")&.truncate(4000),
        )
      end
    } do
      transitions to: :error
    end

    event :reset do
      transitions to: :created
    end
  end

  def doCall!
    reset_response!
    target_url = url
    request_headers = headers
    request_body = body
    verb = method.to_s.downcase
    if ENV["MOCK_WEBHOOKS"] == "true"
      target_url = "https://postman-echo.com/#{verb}"
      request_body = request_body.to_json
      request_headers = (request_headers || {}).merge("Content-Type" => "application/json")
    end
    response = HTTParty.public_send(
      verb,
      target_url,
      headers: request_headers,
      body: request_body,
      timeout: 10,
    )
    update_columns(
      response_code: response.code,
      response_headers: response.headers.to_h,
      response_body: response.body,
    )
    raise "Webhook failed with status #{response.code}" if response.code != 200

    response
  end

  def reset_response!
    update_columns(response_code: nil, response_headers: nil, response_body: nil)
  end

  def response_body
    value = read_attribute(:response_body)
    return value if value.blank?

    JSON.pretty_generate(JSON.parse(value))
  rescue JSON::ParserError
    value
  end

  def response_body_json
    JSON.parse(response_body)
  rescue JSON::ParserError
    nil
  end

  def self.retain_seconds
    seconds = ENV.fetch("WEBHOOK_RETAIN", DEFAULT_RETAIN_SECONDS.to_s).to_i
    seconds.positive? ? seconds : DEFAULT_RETAIN_SECONDS
  end

  def self.purge_expired
    where(created_at: ...retain_seconds.seconds.ago).in_batches(of: 100) do |batch|
      batch.destroy_all
    end
  end
end
