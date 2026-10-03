# frozen_string_literal: true

require "httparty"

module Webhookable
  extend ActiveSupport::Concern

  included do
    has_many :webhooks, as: :webhookable, dependent: :destroy
  end

  def webhook!(method = :post, url = nil, body: nil, headers: nil, async: false, tags: [])
    raise "URL is required" if url.blank?
    raise "Method is required" if method.blank?

    tags = tags.split(",") if tags.is_a?(String)
    tags += [ "mock" ] if ENV["MOCK_WEBHOOKS"] == "true"
    Webhook.create!(
      webhookable: self,
      method: method,
      url: url,
      body: body,
      headers: headers,
      async: async,
      tag_list: tags,
    )
  end
end
