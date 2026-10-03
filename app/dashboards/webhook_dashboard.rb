# frozen_string_literal: true

require "administrate/base_dashboard"

class WebhookDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    webhookable: Field::Polymorphic,
    state: Field::Aasm.with_options(searchable: true, searchable_field: :name),
    async: Field::Boolean,
    method: Field::String,
    url: Field::String,
    body: Field::Text.with_options(searchable: false),
    response_code: Field::Number,
    response_body: Field::Text.with_options(searchable: false),
    response_headers: Field::Text.with_options(searchable: false),
    error_message: Field::Text,
    error_backtrace: Field::Text.with_options(searchable: false),
    created_at: Field::DateTime,
    updated_at: Field::DateTime,
    tags: Field::ActsAsTaggable.with_options(searchable: true)
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    state
    webhookable
    method
    url
    response_code
    tags
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    webhookable
    state
    async
    method
    url
    tags
    body
    response_code
    response_headers
    response_body
    error_message
    error_backtrace
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[
    webhookable
    async
    method
    url
    tags
    body
    response_code
    response_body
  ].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(webhook)
    "Webhook ##{webhook.id} (#{webhook.method} #{webhook.state})"
  end
end
